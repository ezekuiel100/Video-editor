package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import win "core:sys/windows"

// extrai o áudio do vídeo para WAV PCM. WAV é ~12x mais rápido de gerar que
// OGG/MP3 (só decodifica, não codifica); o raylib toca WAV com streaming do
// disco (RAM baixa). Custo: ~10 MB/min de arquivo temporário.
// head=true limita aos primeiros HEAD_SECS (-t antes do -i: o ffmpeg nem lê o
// resto do arquivo, por isso fica pronto em ~1s mesmo em vídeos longos).
// Processo próprio + polling de `stop`: fechar o app aborta o ffmpeg em vez
// de congelar o join esperando a extração (vídeos longos demoram muito).
// dispara a extração (não bloqueia): retorna o processo p/ aguardar depois.
// Separar start/wait deixa o WAV completo ser extraído EM PARALELO à waveform e
// às miniaturas (antes ele só começava depois delas — atrasava muito o áudio
// completo em vídeos longos, prolongando a janela em que adiantar dava mudo).
// SEM -ac fixo: preserva o layout NATIVO do source. O áudio deste VOD é MONO;
// forçar "-ac 2" duplicava o mono em 2 canais e a reprodução saía picotando só
// num dos lados. Mono nativo -> WAV mono -> o raylib expande igual nos 2 ouvidos.
audio_extract_start :: proc(c: ^Clip, out: string, head: bool) -> (os.Process, bool) {
	head_cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-t", fmt.tprintf("%.0f", HEAD_SECS), "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	full_cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	ap, ape := os.process_start(os.Process_Desc{ command = head ? head_cmd : full_cmd })
	if ape != nil do return {}, false
	tame_process(c, ap, !head) // head é curto e sensível a latência; completo é fundo
	return ap, true
}

// aguarda a extração terminar; polling de `stop` p/ abortar se o app fechar.
audio_extract_wait :: proc(c: ^Clip, ap: os.Process) -> bool {
	for {
		if intrinsics.atomic_load(&c.stop) { // app fechando: mata e sai
			_ = os.process_kill(ap)
			_, _ = os.process_wait(ap)
			return false
		}
		state, werr := os.process_wait(ap, 50 * time.Millisecond)
		if state.exited do return state.exit_code == 0
		if werr != nil && werr != os.General_Error.Timeout do return false // erro real
	}
}

audio_extract :: proc(c: ^Clip, out: string, head: bool) -> bool {
	ap, ok := audio_extract_start(c, out, head)
	if !ok do return false
	return audio_extract_wait(c, ap)
}

// ----- áudio completo em partes -----
part_path :: proc(c: ^Clip, k: int) -> string { // OGG: pequeno (~90MB p/ 5h) e decodificado pelo stb_vorbis, não o drwav
	return fmt.tprintf("%s_full.ogg", c.aud_path)
}

// worker: extrai o áudio COMPLETO num ÚNICO WAV (o raylib NÃO tem FLAC embutido;
// suporta wav/ogg/mp3/qoa). Com o áudio MONO, 5h de WAV s16 = ~1.6GB — cabe no
// fseek de 32 bits do dr_wav (o estéreo passava de 2GB; foi por isso que fatiei
// em partes, e a troca de stream em CADA fronteira era o picote "sempre nas
// mesmas partes"). WAV gera em ~12s (só decodifica), então o head cobre a ponte.
// Um arquivo só = seek limpo em qualquer ponto, ZERO fronteiras.
// Salvaguarda: acima de ~6h a 48kHz o WAV passaria de 2GB -> baixa a taxa p/ caber.
parts_worker :: proc(c: ^Clip) {
	// OGG (libvorbis) em vez de WAV: o WAV único de 1.58GB fazia o rl.Music/drwav
	// CHIAR (som granulado, underrun=0, só neste vídeo/áudio grande; head e chunks
	// pequenos tocavam limpos). OGG comprime 5h em ~90MB, tamanho parecido com os
	// chunks que funcionam, e usa o stb_vorbis (decoder diferente). ~3-4min p/ gerar
	// (o head + chunks cobrem a ponte). Qualidade cheia de 48kHz.
	cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vn", "-c:a", "libvorbis", "-q:a", "4", part_path(c, 0),
	}
	ok := false
	if ap, ape := os.process_start(os.Process_Desc{ command = cmd }); ape == nil {
		tame_process(c, ap, true) // fundo: o head cobre a interatividade até ficar pronto
		ok = audio_extract_wait(c, ap)
	}
	if ok do intrinsics.atomic_store(&c.parts_done, 1)
	intrinsics.atomic_store(&c.ogg_ok, ok)
	intrinsics.atomic_store(&c.ogg_done, true)
}

// (main) troca a janela de áudio ativa pelo FLAC completo (cobre o vídeo inteiro),
// assim que ele fica pronto. Uma única troca (head -> completo), sem fronteiras
// depois. true = c.music tem relógio válido em `local`.
try_part_open :: proc(c: ^Clip, local: f32) -> bool {
	if audio_clock_ok(c, local) do return true
	if intrinsics.atomic_load(&c.parts_done) < 1 do return false // FLAC ainda não pronto
	// o stream ativo JÁ é o arquivo completo? então não existe janela melhor — sair sem
	// descarregar. Antes isto era deduzido da duração (end >= dur-0.5), e um áudio mais
	// curto que o vídeo (mic que para antes do fim) reprovava no teste: o completo era
	// confundido com o head e trocado por ele MESMO a cada frame da cauda (Unload+Load de
	// um OGG de ~90MB por frame). O guard antigo por !c.streaming só cobria o cache.
	if c.has_audio && c.music_full do return false
	if c.has_audio { rl.UnloadMusicStream(c.music); c.has_audio = false }
	if !music_open(c, part_path(c, 0)) do return false
	c.music_base = 0
	c.music_full = true
	return audio_clock_ok(c, local)
}

// ----- áudio sob demanda (janela móvel) -----
// worker: extrai CHUNK_SECS de áudio a partir de c.chunk_req (-ss antes do -i:
// seek de entrada, rápido mesmo fundo num vídeo de horas — fica pronto em ~1-2s)
chunk_worker :: proc(c: ^Clip) {
	base := c.chunk_req
	out := c.aud_ck[c.chunk_slot]
	cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-ss", fmt.tprintf("%.2f", base), "-t", fmt.tprintf("%.0f", CHUNK_SECS), "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	ap, ape := os.process_start(os.Process_Desc{ command = cmd })
	if ape == nil {
		tame_process(c, ap, false) // sensível a latência: o usuário está esperando o som
		c.chunk_base = base     // antes do done: a main só lê depois do atomic
		if audio_extract_wait(c, ap) do intrinsics.atomic_store(&c.chunk_ok, true)
	}
	intrinsics.atomic_store(&c.chunk_done, true)
}

// (main) adota o chunk PRONTO se ele cobre `local` e a posição ainda não tem
// relógio. Separado da chegada (audio_load_ready): um chunk pré-buscado fica
// "no bolso" até o playback entrar na área — troca instantânea na borda, sem gap.
try_chunk_open :: proc(c: ^Clip, local: f32) -> bool {
	if audio_clock_ok(c, local) do return true
	if c.chunk_busy do return false // ainda extraindo
	if !intrinsics.atomic_load(&c.chunk_done) || !intrinsics.atomic_load(&c.chunk_ok) do return false
	// cobertura REAL do chunk (medida na 1ª abertura), não a nominal: o ffmpeg entrega menos
	// que -t quando o áudio da fonte acaba antes. Com a nominal, um ponto fora do arquivo
	// caía aqui como "coberto", reabria o mesmo WAV todo frame e o chamador nunca pedia outro.
	if local < c.chunk_base || local >= c.chunk_base + chunk_cov_of(c) - 0.5 do return false
	// abre ANTES de descartar o que está tocando: descarregar primeiro e só então descobrir
	// que o chunk novo está vazio jogava fora o OGG completo, que o audio_load_ready
	// recarregava inteiro no frame seguinte (centenas de ms na main, a cada ciclo)
	m, mok := music_load(c.aud_ck[c.chunk_slot])
	c.chunk_meas = true
	if !mok {
		c.chunk_cov = 0 // vazio: não cobre nada
		// e o vazio PROVA que o áudio da fonte acaba em algum ponto <= esta base: registra,
		// senão o chunk_request pede o mesmo trecho de novo (um ffmpeg por ciclo, p/ sempre)
		if c.aud_end <= 0 || c.chunk_base < c.aud_end do c.aud_end = c.chunk_base
		return false
	}
	if c.has_audio do rl.UnloadMusicStream(c.music)
	c.music = m; c.has_audio = true
	c.chunk_cov = f32(m.frameCount) / f32(max(m.stream.sampleRate, 1))
	c.music_full = false
	c.music_base = c.chunk_base
	c.music_slot = c.chunk_slot // este slot agora está preso pelo dr_wav
	// só confirma se o relógio realmente cobre o ponto (o try_part_open já fazia assim):
	// um `true` sem cobertura suprimia o chunk_request do chamador para sempre
	return audio_clock_ok(c, local)
}

// cobertura do chunk no bolso: a medida real quando já conhecida, senão a nominal
chunk_cov_of :: proc(c: ^Clip) -> f32 { return c.chunk_meas ? c.chunk_cov : CHUNK_SECS }

// (main) pede um chunk cobrindo `local`. Ignora se já há um worker no ar (quando
// ele terminar, se o playhead saiu da área, pede-se outro) ou se o chunk no bolso
// já cobre. Chame try_part_open/try_chunk_open antes.
chunk_request :: proc(c: ^Clip, local: f32) {
	if c.chunk_busy do return
	// já se descobriu (por um chunk que voltou vazio) que o áudio da fonte acaba antes daqui:
	// pedir de novo só gastaria um ffmpeg por ciclo, para sempre, e o resultado seria o mesmo
	// arquivo só-cabeçalho. O aud_end é reconhecidamente conservador (só marca o que foi
	// PROVADO vazio), então nunca barra um trecho que tem som.
	if c.aud_end > 0 && local >= c.aud_end do return
	if intrinsics.atomic_load(&c.chunk_done) && intrinsics.atomic_load(&c.chunk_ok) &&
	   local >= c.chunk_base && local < c.chunk_base + chunk_cov_of(c) - 0.5 {
		return // já no bolso (pela cobertura REAL, não pela nominal)
	}
	if c.chunk_thr != nil { thread.join(c.chunk_thr); thread.destroy(c.chunk_thr); c.chunk_thr = nil }
	// NUNCA escreve no slot aberto em c.music: o ffmpeg (-y) trunca o arquivo na
	// hora, e tocar um WAV sendo regravado vira ruído/starvation (picote). A
	// alternância cega por paridade caía no slot ativo quando um chunk extraído
	// não era adotado (usuário adiantou de novo antes de ele ficar pronto).
	c.chunk_slot = c.music_slot >= 0 ? c.music_slot ~ 1 : c.chunk_slot ~ 1
	c.chunk_req = clamp(local - 1, 0, c.dur) // margem de 1s antes do pedido
	c.chunk_meas = false; c.chunk_cov = 0 // cobertura do chunk NOVO só é conhecida ao abrir
	intrinsics.atomic_store(&c.chunk_done, false)
	intrinsics.atomic_store(&c.chunk_ok, false)
	c.chunk_busy = true
	c.chunk_thr = thread.create_and_start_with_poly_data(c, chunk_worker)
}

// carrega um arquivo como rl.Music pronto p/ tocar (pausado no início), SEM tocar em clipe
// nenhum — quem chama decide se troca o stream ativo por este. ok=false quando o arquivo não
// abre ou abre com 0 amostras (o ffmpeg grava só o header quando o trecho pedido está além do
// fim do áudio): aí o raylib JÁ alocou o decoder e registrou o AudioStream no mixer, então
// precisa do Unload — sair sem ele vazava um buffer por tentativa, num caminho retentado a
// cada frame. ctxData nil = a carga falhou de vez, não há o que descarregar.
music_load :: proc(path: string) -> (rl.Music, bool) {
	m := rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	if m.frameCount == 0 {
		if m.ctxData != nil do rl.UnloadMusicStream(m)
		return {}, false
	}
	m.looping = false
	rl.PlayMusicStream(m)
	rl.PauseMusicStream(m)
	return m, true
}

// abre um WAV como rl.Music do clipe, pausado no início; false se inválido
music_open :: proc(c: ^Clip, path: string) -> bool {
	m, ok := music_load(path)
	if !ok { c.music = {}; return false }
	c.music = m
	c.music_base = 0 // head/completo começam na origem; quem abre chunk sobrescreve
	c.music_full = false // quem abre o part_path(c,0) completo marca depois
	c.music_slot = -1 // não é um slot de chunk; try_chunk_open sobrescreve ao abrir chunk
	c.has_audio = true
	return true
}

// carrega/atualiza o áudio dos clipes (main thread). Dois estágios: o head
// (30s) entra assim que fica pronto — som quase imediato em vídeos longos —
// e é trocado pelo WAV completo no fim, preservando posição e estado de play.
audio_load_ready :: proc() {
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed do continue // slot removido (tombstone): recursos já liberados
		// chunk terminou de extrair: fica "no bolso" (adoção via try_chunk_open).
		// Se o playhead JÁ está na área e sem relógio (chegada no meio do mudo),
		// adota na hora — o playback re-adquire no frame seguinte.
		if c.chunk_busy && intrinsics.atomic_load(&c.chunk_done) {
			c.chunk_busy = false
			if a := seg_at(st.playhead); a >= 0 && segs[a].src == i {
				_ = try_chunk_open(c, seg_local(a, st.playhead))
			}
		}
		if !c.has_audio {
			// 1ª carga: WAV completo se já existe, senão o head
			if intrinsics.atomic_load(&c.parts_done) >= 1 {
				if music_open(c, part_path(c, 0)) do c.music_full = true // music_base = 0
			} else if intrinsics.atomic_load(&c.head_done) && intrinsics.atomic_load(&c.head_ok) {
				if !music_open(c, c.aud_head) do intrinsics.atomic_store(&c.head_ok, false)
			}
			continue
		}
		// troca PROATIVA head->completo assim que o WAV fica pronto (~12s após import):
		// feita cedo, quando o usuário nem começou a tocar, o gap da troca é inaudível
		// — e evita o gap acontecer no minuto 1 (fim do head) durante o playback.
		full_ready := intrinsics.atomic_load(&c.parts_done) >= 1
		// "é o head?" pela IDENTIDADE do stream, não pela duração: com áudio mais curto que o
		// vídeo o completo também mede < dur-0.5, e a troca abaixo o substituía por ele mesmo
		// a cada frame (Unload+Load do OGG inteiro, com o playback picotando junto).
		is_head := c.music_base == 0 && !c.music_full
		// NUNCA troca head→OGG completo DURANTE o play: LoadMusicStream de ~90MB
		// na main trava a UI por segundos (o usuário só está assistindo). Espera pausar.
		if full_ready && is_head && st.drag == .None && !st.playing {
			pos := play_clip >= 0 && segs[play_clip].src == i ? rl.GetMusicTimePlayed(c.music) : -1
			resume := st.playing && play_clip >= 0 && segs[play_clip].src == i
			rl.UnloadMusicStream(c.music); c.has_audio = false
			// fonte tocando como SECUNDÁRIO (mix): zera mix_on — o stream novo nasce pausado
			// em 0, e com mix_on=true o audio_secondary dava Resume ANTES de reposicionar
			// (blip do começo do arquivo). Com false, ele re-adquire na posição certa.
			c.mix_on = false
			if music_open(c, part_path(c, 0)) {
				c.music_full = true
				if pos >= 0 { rl.SeekMusicStream(c.music, pos); if resume do rl.ResumeMusicStream(c.music) }
			}
		}
	}
}

// o music do clipe pode servir de relógio em `local`? O stream ativo é sempre
// uma JANELA [music_base, music_base + duração do arquivo): head (base 0),
// chunk sob demanda, ou uma parte do completo. Fora da cobertura o playback cai
// pro relógio de parede (mudo) e adota a parte pronta ou encomenda um chunk.
audio_clock_ok :: proc(c: ^Clip, local: f32) -> bool {
	if !c.has_audio do return false
	end := c.music_base + f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
	return local >= c.music_base && local < end - 0.25
}

// true = o stream aberto em `c.music` JÁ é o OGG completo (base 0, cobrindo ~toda a
// duração) E esse arquivo existe no disco. Vive numa proc própria porque errar aqui
// deixa o clipe MUDO em silêncio, e assim dá p/ testar sem dispositivo de áudio.
// `parts_done >= 1` é OBRIGATÓRIO: sem ele o seek descarregava o stream que estava
// funcionando (head/chunk) e o music_open falhava no _full.ogg que o parts_worker
// AINDA estava gerando -> has_audio=false = clipe mudo. Aparecia com vários vídeos
// porque os parts_worker rodam em prioridade baixa e brigam entre si, então o ogg do
// clipe pra onde você pula costuma não estar pronto. Os outros pontos que abrem
// part_path(c,0) já checavam isso (try_part_open e as duas cargas do audio_load_ready).
audio_full_window_ready :: proc(c: ^Clip) -> bool {
	if intrinsics.atomic_load(&c.parts_done) < 1 do return false
	if !c.has_audio || c.music_base != 0 do return false
	return f32(c.music.frameCount) / f32(c.music.stream.sampleRate) >= c.dur - 1.0
}

// define o segmento que fornece o áudio-relógio e o inicia em `local` (na FONTE)
set_play_clip :: proc(si: int, local: f32) {
	if play_clip >= 0 && play_clip != si && seg_src(play_clip).has_audio {
		rl.PauseMusicStream(seg_src(play_clip).music)
	}
	play_clip = si
	aud_prev = -1; smooth_bad = 0 // relógio suave recomeça após seek/aquisição (âncora = loc0 no bloco)
	c := seg_src(si)
	// troca a janela p/ a parte da região ou o chunk no bolso, se prontos
	if c.has_audio && !try_part_open(c, local) do _ = try_chunk_open(c, local)
	if c.has_audio && audio_clock_ok(c, local) {
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(local - c.music_base, 0, msdur) // posição no ARQUIVO ativo
		// Stop + Seek (nunca Unload+Load do OGG de ~90MB): recarregar na main
		// a cada seek congelava o editor. O Stop descarta os sub-buffers velhos
		// (senão tocava ~0.5s da posição antiga).
		rl.StopMusicStream(c.music)
		rl.SeekMusicStream(c.music, target)
		rl.PlayMusicStream(c.music)
		for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
		seek_pending = true
		seek_pending_loc = clamp(local, 0, c.dur) // coords da FONTE (o playback compara nelas)
	} else if c.has_audio {
		chunk_request(c, local) // encomenda o áudio da região
	}
}

// MIXAGEM: toca em sincronia com o master TODOS os clipes com áudio sob o playhead que
// NÃO são o master — trilhas de áudio (música) E vídeos EMPILHADOS (o de baixo, quando o
// de cima é o relógio). O raylib soma os streams no device. Chamado todo frame — quando
// pausado/fora do clipe, silencia. NÃO mexe no relógio (master). Fontes LONGAS (streaming,
// áudio em janelas) podem não casar como secundário; o caso comum (clipes curtos) funciona.
// arrasto que NÃO deve silenciar o playback (volume/fade/transição): igual ao bloco
// do master — o usuário está ajustando áudio e precisa OUVIR a mudança ao vivo.
// Antes o secundário/spv exigiam drag==None e mutavam justamente o que era ajustado.
audio_edit_drag :: proc() -> bool {
	return st.drag == .Vol || st.drag == .FadeIn || st.drag == .FadeOut || st.drag == .TransDur || st.drag == .FxCenter
}

audio_secondary :: proc() {
	pt := prof_beg(.Audio); defer prof_end(.Audio, pt)
	// passada 1: elege, POR FONTE, o segmento que a toca neste frame (1 rl.Music não
	// toca 2 posições — mesma fonte 2x sob o playhead: o de trilha mais baixa vence,
	// o outro fica mudo). Sem eleição, um seg fora do playhead pausava o stream que
	// outro seg queria tocar, em loop (picote).
	win: [MAX_CLIPS]int
	for k in 0 ..< MAX_CLIPS do win[k] = -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || i == play_clip do continue
		// não gerencie a MESMA fonte do master aqui (o loop principal já cuida do c.music dela)
		if play_clip >= 0 && play_clip < nsegs && segs[i].src == segs[play_clip].src do continue
		if seg_speed(i) != 1 do continue // velocidade != 1: o áudio vem do spv (tom preservado)
		if !seg_src(i).has_audio do continue
		sg := &segs[i]
		inside := st.playhead >= sg.start && st.playhead < sg.start + sg.dur
		if !(st.playing && (st.drag == .None || audio_edit_drag()) && inside && !sg.muted && !track_muted[sg.track]) do continue
		if win[sg.src] < 0 || segs[i].track < segs[win[sg.src]].track do win[sg.src] = i
	}
	// passada 2: gerencia cada fonte secundária — toca o vencedor, pausa as demais
	for s in 0 ..< nclips {
		c := &clips[s]
		if c.closed || !c.has_audio do continue
		if play_clip >= 0 && play_clip < nsegs && segs[play_clip].src == s do continue // master cuida
		i := win[s]
		if i < 0 {
			if c.mix_on { rl.PauseMusicStream(c.music); c.mix_on = false }
			continue
		}
		sg := &segs[i]
		local := seg_local(i, st.playhead)
		// o stream ativo é uma JANELA da fonte (head/chunk/completo, offset music_base)
		// — igual ao master. Antes isto seekava `local` cru no arquivo ativo: em clipes
		// longos tocava a posição ERRADA (ou o fim do head) = áudio "bugado" ao sobrepor.
		if !audio_clock_ok(c, local) {
			if c.mix_on { rl.PauseMusicStream(c.music); c.mix_on = false }
			// adota a parte completa ou o chunk no bolso; senão encomenda um chunk —
			// o som desta trilha volta quando a janela cobrir (~1-2s)
			if !try_part_open(c, local) && !try_chunk_open(c, local) do chunk_request(c, local)
			continue
		}
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(local - c.music_base, 0, msdur) // posição no ARQUIVO ativo
		if !c.mix_on {
			rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target); rl.PlayMusicStream(c.music)
			for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
			c.mix_on = true
		} else {
			if !rl.IsMusicStreamPlaying(c.music) do rl.ResumeMusicStream(c.music)
			rl.UpdateMusicStream(c.music)
			if abs((rl.GetMusicTimePlayed(c.music) + c.music_base) - local) > 0.3 {
				// corrige drift re-ADQUIRINDO: o Seek do raylib não descarta os buffers
				// já enfileirados (tocaria ~0.7s do áudio antigo) — Stop zera e o
				// Update pré-enche com o áudio novo
				rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target); rl.PlayMusicStream(c.music)
				for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
			}
		}
		// pré-busca: perto do fim da janela ativa e ainda falta segmento -> encomenda
		// o próximo chunk JÁ (troca na borda sem ficar mudo esperando a extração)
		cend := c.music_base + msdur
		if cend < sg.in_off + sg.dur && local > cend - 15 {
			if int((cend + 1) / FULL_PART) >= intrinsics.atomic_load(&c.parts_done) {
				chunk_request(c, cend - 1)
			}
		}
		rl.SetMusicVolume(c.music, seg_gain(i, st.playhead) * player_vol)
	}
}

// segmento que fica com o stream ÚNICO (c.music) da fonte sob o playhead: o master (play_clip)
// se for dessa fonte; senão o de trilha mais BAIXA (mesma regra do audio_secondary). Só speed==1
// disputa o c.music (speed!=1 sempre vem do spv).
music_owner_of :: proc(src: int) -> int {
	if play_clip >= 0 && play_clip < nsegs && segs[play_clip].src == src do return play_clip
	owner := -1
	for i in 0 ..< nsegs {
		sg := segs[i]
		if sg.src != src || !seg_ready(i) || !seg_src(i).has_audio || seg_speed(i) != 1 do continue
		if sg.muted || track_muted[sg.track] do continue
		if !(st.playhead >= sg.start && st.playhead < sg.start + sg.dur) do continue
		if owner < 0 || sg.track < segs[owner].track do owner = i
	}
	return owner
}

// o segmento i precisa do PRÓPRIO áudio (via spv) por sobrepor outro da MESMA fonte que já ocupa
// o c.music (1 rl.Music não toca 2 posições — antes o duplicado ficava mudo). Só quando o conteúdo
// DIFERE do dono: cópias idênticas empilhadas seguem com um único áudio (sem eco/dobra).
seg_audio_dup :: proc(i: int) -> bool {
	if !seg_ready(i) || !seg_src(i).has_audio || seg_speed(i) != 1 do return false
	sg := segs[i]
	if sg.muted || track_muted[sg.track] do return false
	if !(st.playhead >= sg.start && st.playhead < sg.start + sg.dur) do return false
	owner := music_owner_of(sg.src)
	if owner < 0 || owner == i do return false
	return abs(seg_local(i, st.playhead) - seg_local(owner, st.playhead)) >= 0.05 // posição na fonte difere
}

// ---- preview de VELOCIDADE com tom preservado (time-stretch via ffmpeg atempo) ----
// O SetMusicPitch do raylib só reamostra (muda o TOM: voz fina/grossa). Para o
// preview soar natural, cada segmento com speed != 1 tem um WAV pré-renderizado com
// EXATAMENTE `dur` segundos e tom corrigido (o mesmo atempo do export), tocado a 1x
// e sincronizado ao playhead — como a mixagem secundária (aditivo, NÃO é relógio).
// O WAV é gerado por JANELAS de SPV_CHUNK segundos de timeline, não pelo segmento
// inteiro: um clipe de 30 min viraria um WAV de centenas de MB e dezenas de segundos
// de render (antes havia um teto SPV_MAX_DUR e acima dele o preview ficava MUDO, sem
// aviso — o bug "acelerei e o áudio parou"). Cada segmento tem 2 slots alternados
// (slot = índice da janela & 1) para a janela seguinte ser pré-renderizada enquanto a
// atual toca: a troca na borda não tem buraco. Mesma ideia dos chunks do áudio normal.
SPV_CHUNK :: f32(120) // segundos de TIMELINE por WAV
SPV_PRE   :: f32(25)  // começa a próxima janela a esta distância do fim da atual

Spv :: struct {
	music: rl.Music,
	ok:    bool,   // main: WAV carregado e válido
	on:    bool,   // main: tocando agora
	key:   u64,    // conteúdo (src/in_off/dur/speed) + janela que gerou o arquivo
	path:  string, // WAV temporário (heap, dono)
	// render que FALHOU: sem isto o pedido é refeito todo frame (um processo ffmpeg
	// por frame, mudo, para sempre). Desiste após SPV_TRIES e avisa uma vez.
	bad_key: u64,
	bad_n:   int,
}
SPV_TRIES :: 3
spv: [MAX_SEGS][2]Spv
spv_render_idx:  int = -1     // segmento sendo renderizado (só a main escreve; -1 = ocioso)
spv_render_slot: int          // slot alvo do render em voo
spv_render_ci:   int          // janela alvo do render em voo
spv_render_path: string       // WAV sendo escrito agora (heap, dono até spv_poll)
spv_serial:      int          // sufixo único: cada render vai p/ um arquivo novo
spv_render_key:  u64          // key alvo do render em voo
spv_args:        []string     // argv do ffmpeg (heap; liberado após o render)
spv_thr:         ^thread.Thread
spv_done:        bool         // atômico: worker terminou
spv_ok:          bool         // atômico: ffmpeg saiu com sucesso

// número de janelas do segmento (>=1, mesmo em segmentos curtíssimos)
spv_nchunks :: proc(i: int) -> int { return max(1, int(math.ceil(segs[i].dur / SPV_CHUNK))) }

// identidade do CONTEÚDO de áudio de uma JANELA (independe do índice do segmento, que
// desloca ao remover): fonte + trecho + velocidade + janela. Muda => regerar o WAV.
spv_key :: proc(i, ci: int) -> u64 {
	sg := segs[i]
	h: u64 = 1469598103934665603
	h = (h ~ u64(u32(sg.src)))                 * 1099511628211
	h = (h ~ u64(transmute(u32)sg.in_off))     * 1099511628211
	h = (h ~ u64(transmute(u32)sg.dur))        * 1099511628211
	h = (h ~ u64(transmute(u32)seg_speed(i)))  * 1099511628211
	h = (h ~ u64(u32(ci)))                     * 1099511628211
	return h
}

// LIXEIRA dos WAVs aposentados: o os.remove falha (sharing violation) enquanto o
// raylib não solta o handle do stream — e ele demora alguns frames depois do Unload.
// Apagar na hora deixava ~23 MB por ajuste de velocidade para trás. Aqui a remoção é
// tentada de novo a cada frame até passar.
spv_trash: [dynamic]string

spv_trash_take :: proc(p: string) { if p != "" do append(&spv_trash, p) } // assume a posse

spv_trash_sweep :: proc() {
	for k := len(spv_trash) - 1; k >= 0; k -= 1 {
		if os.remove(spv_trash[k]) == nil { delete(spv_trash[k]); unordered_remove(&spv_trash, k) }
	}
}

// algum slot de spv[i] guarda um render que NÃO pode pertencer ao segmento i de agora?
// A chave é conteúdo puro (fonte+trecho+velocidade+janela), então isto só dá true quando o
// índice passou a ser de outro segmento — nunca por o playhead ter saído de cima dele.
// O slot s só recebe janelas com (ci & 1) == s (ver audio_speed_preview).
spv_orphan :: proc(i: int) -> bool {
	n := spv_nchunks(i)
	for s in 0 ..< 2 {
		e := &spv[i][s]
		if !e.ok && e.path == "" do continue // slot vazio
		hit := false
		for ci := s; ci < n; ci += 2 do if e.key == spv_key(i, ci) { hit = true; break }
		if !hit do return true
	}
	return false
}

spv_release :: proc(i: int) {
	for s in 0 ..< 2 {
		e := &spv[i][s]
		if e.ok { rl.UnloadMusicStream(e.music); e.ok = false }
		spv_trash_take(e.path); e.path = ""
		e.on = false; e.key = 0
	}
}

// worker de fundo: renderiza o WAV esticado (1 por vez). Lê só globals (sem alocar).
spv_worker :: proc() {
	ok := false
	// captura o stderr do ffmpeg: sem isso uma falha de render vira só "ok=false" e o
	// motivo se perde (o editor então retenta em laço, mudo, sem ninguém saber por quê)
	desc := os.Process_Desc{ command = spv_args }
	er, ew, epe := os.pipe()
	if epe == nil do desc.stderr = ew
	p, pe := os.process_start(desc)
	if epe == nil do os.close(ew) // a ponta de escrita agora é do filho
	if pe != nil {
		when DBG_SPV do fmt.eprintfln("[spv] SPAWN FALHOU: %v", pe)
	}
	if pe == nil {
		job := make_kill_job() // morre junto com o editor se fechar no meio
		if job != nil do AssignProcessToJobObject(job, win.HANDLE(p.handle))
		// drena o stderr ATÉ O EOF **antes** de esperar o processo. A ordem importa: o
		// buffer do pipe é finito, então um stderr gordo bloquearia o ffmpeg no write —
		// ele nunca sairia e o poll abaixo giraria p/ sempre. Drenar depois do wait (como
		// era) não previne nada: é o wait que trava primeiro. O EOF só chega quando o
		// filho fecha a ponta dele, ou seja, ao terminar — então isto já serve de espera
		// e o poll seguinte retorna de imediato. `app_closing` é visto ENTRE leituras,
		// mesmo idioma do compute_waveform.
		if epe == nil {
			buf: [4096]u8
			for {
				if intrinsics.atomic_load(&app_closing) { _ = os.process_kill(p); break }
				n, rerr := os.read(er, buf[:])
				when DBG_SPV do if n > 0 do fmt.eprintfln("[spv] FFMPEG: %s", string(buf[:n]))
				if n <= 0 || rerr != nil do break
			}
		}
		for { // poll: se o app fechar, mata o render em voo em vez de esperar terminar
			if intrinsics.atomic_load(&app_closing) { _ = os.process_kill(p); _, _ = os.process_wait(p); break }
			state, we := os.process_wait(p, 50 * time.Millisecond)
			if state.exited { ok = we == nil && state.exit_code == 0; break }
			if we != nil && we != os.General_Error.Timeout do break
		}
		if job != nil do win.CloseHandle(job)
	}
	if epe == nil do os.close(er)
	intrinsics.atomic_store(&spv_ok, ok)
	intrinsics.atomic_store(&spv_done, true)
}

// monta a cadeia atempo (0.5..2 por estágio) p/ cobrir 0.25..4 — igual ao export.
spv_atempo :: proc(sp: f32) -> string {
	b := strings.builder_make(context.temp_allocator)
	r := sp
	for r > 2.0 + 0.001 { fmt.sbprintf(&b, "atempo=2.0,"); r /= 2 }
	for r < 0.5 - 0.001 { fmt.sbprintf(&b, "atempo=0.5,"); r *= 2 }
	fmt.sbprintf(&b, "atempo=%.5f", r)
	return strings.to_string(b)
}

// dispara (se ocioso) o render do WAV da JANELA ci do segmento i. Enquanto não fica
// pronto, o segmento toca MUDO no preview (nunca com tom cru) — some em ~1-2s.
spv_request :: proc(i, ci: int, k: u64) {
	if spv_render_idx >= 0 do return // um render por vez; os outros tentam no próximo frame
	slot := ci & 1
	sg := segs[i]
	c  := seg_src(i)
	sp := seg_speed(i)
	base := f32(ci) * SPV_CHUNK            // início da janela no tempo do SEGMENTO
	clen := min(SPV_CHUNK, sg.dur - base)  // a última janela é mais curta
	ss   := sg.in_off + base * sp          // ponto correspondente na FONTE
	span := clen * sp                      // trecho da fonte a ler (rende `clen` após o atempo)
	// arquivo NOVO a cada render, nunca reescrita: o rl.Music toca em STREAMING e
	// segura o handle do WAV enquanto estiver carregado — o ffmpeg -y no mesmo caminho
	// dava "Permission denied" (era o bug do áudio mudo ao mexer na velocidade).
	// O antigo só é apagado quando o novo é adotado (spv_poll).
	spv_serial += 1
	spv_render_path = fmt.aprintf("%s_%d_%d_spv%d_%d_%d.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid, i, slot, spv_serial)
	args := make([dynamic]string) // heap: precisa viver até o worker rodar o process_start
	append(&args, strings.clone("ffmpeg"), strings.clone("-y"), strings.clone("-hide_banner"),
		strings.clone("-loglevel"), strings.clone("error"),
		strings.clone("-ss"), fmt.aprintf("%.3f", ss),
		strings.clone("-t"),  fmt.aprintf("%.3f", span),
		strings.clone("-i"),  strings.clone(c.path),
		strings.clone("-vn"), strings.clone("-filter:a"), strings.clone(spv_atempo(sp)),
		strings.clone("-c:a"), strings.clone("pcm_s16le"), strings.clone(spv_render_path))
	when DBG_SPV do fmt.eprintfln("[spv] REQ i=%d ci=%d slot=%d ss=%.3f clen=%.3f sp=%.3f span=%.3f", i, ci, slot, f64(ss), f64(clen), f64(sp), f64(span))
	spv_args = args[:]
	spv_render_idx = i
	spv_render_slot = slot
	spv_render_ci = ci
	spv_render_key = k
	intrinsics.atomic_store(&spv_done, false)
	spv_thr = thread.create_and_start(spv_worker)
}

// adota o render terminado (LoadMusicStream é GL/áudio -> só na main).
spv_poll :: proc() {
	if spv_render_idx < 0 || !intrinsics.atomic_load(&spv_done) do return
	i := spv_render_idx
	if spv_thr != nil { thread.join(spv_thr); thread.destroy(spv_thr); spv_thr = nil }
	ok := intrinsics.atomic_load(&spv_ok)
	for s in spv_args do delete(s) // libera o argv clonado
	delete(spv_args); spv_args = nil
	when DBG_SPV do fmt.eprintfln("[spv] DONE i=%d ci=%d ffmpeg_ok=%v nsegs=%d ready=%v key_now=%d key_req=%d",
		i, spv_render_ci, ok, nsegs, i < nsegs ? seg_ready(i) : false, i < nsegs ? spv_key(i, spv_render_ci) : 0, spv_render_key)
	adopted := false
	// só adota se o segmento ainda existe e nada mudou (senão o WAV está obsoleto)
	if ok && i < nsegs && seg_ready(i) && spv_key(i, spv_render_ci) == spv_render_key {
		e := &spv[i][spv_render_slot]
		// solta o WAV anterior deste slot (fecha o handle) e só então o apaga
		if e.ok { rl.UnloadMusicStream(e.music); e.ok = false; e.on = false }
		spv_trash_take(e.path)                          // some quando o handle cair
		e.path = spv_render_path; spv_render_path = "" // o slot passa a ser o dono
		adopted = true
		// mesma guarda do music_load: um WAV só com CABEÇALHO (o ffmpeg sai com 0 quando o
		// trecho pedido está além do fim do áudio) deixa o raylib com o decoder e o
		// AudioStream alocados e o handle do arquivo preso. Como e.ok fica false, nem o
		// spv_release nem o close_now descarregavam — e o pedido era refeito para sempre,
		// porque a contagem de falhas mora no ramo `!ok` e o ffmpeg tinha dado certo. Cada
		// ciclo vazava um stream, deixava um WAV no %TEMP% e subia outro ffmpeg.
		m, mok := music_load(e.path)
		if mok { e.music = m; e.ok = true; e.key = spv_render_key }
		else { // conta como falha p/ o SPV_TRIES desarmar o laço
			e.music = {}
			if e.bad_key == spv_render_key do e.bad_n += 1
			else { e.bad_key = spv_render_key; e.bad_n = 1 }
			if e.bad_n == SPV_TRIES do set_toast("Não consegui preparar o áudio nesta velocidade")
		}
		when DBG_SPV do fmt.eprintfln("[spv] LOAD i=%d frames=%d rate=%d ok=%v", i, e.music.frameCount, e.music.stream.sampleRate, e.ok)
		e.on = false
	} else if !ok && i < nsegs && spv_key(i, spv_render_ci) == spv_render_key {
		// render falhou p/ este conteúdo: conta e, no limite, desiste (com aviso) em vez
		// de respawnar o ffmpeg todo frame
		e := &spv[i][spv_render_slot]
		if e.bad_key == spv_render_key do e.bad_n += 1
		else { e.bad_key = spv_render_key; e.bad_n = 1 }
		if e.bad_n == SPV_TRIES do set_toast("Não consegui preparar o áudio nesta velocidade")
	}
	if !adopted && spv_render_path != "" { // render descartado (falhou ou já obsoleto)
		spv_trash_take(spv_render_path); spv_render_path = ""
	}
	spv_render_idx = -1
}

// toca, em sincronia com o playhead, o áudio pré-renderizado dos segmentos com
// speed != 1 sob o playhead. Chamado todo frame junto com audio_secondary.
spv_dbg_tick: int
audio_speed_preview :: proc() {
	pt := prof_beg(.Audio); defer prof_end(.Audio, pt)
	when DBG_SPV do spv_dbg_tick += 1
	spv_trash_sweep() // reaposenta os WAVs que o raylib acabou de soltar
	for i := nsegs; i < MAX_SEGS; i += 1 do if spv[i][0].ok || spv[i][0].path != "" || spv[i][1].ok || spv[i][1].path != "" do spv_release(i) // limpa slots mortos
	for i in 0 ..< nsegs {
		// usa o WAV por-segmento (spv) quando o áudio da fonte NÃO pode vir do c.music:
		// velocidade != 1 (tom preservado) OU duplicado (mesma fonte já ocupa o c.music).
		uses_spv := seg_ready(i) && seg_src(i).has_audio && (seg_speed(i) != 1 || seg_audio_dup(i))
		// o slot guarda o render de OUTRO segmento? spv é indexado por segmento, mas segs[]
		// é compactado em remove_seg/remove_media (sem deslocar spv, ao contrário de
		// seg_marked) e trocado inteiro no undo/redo. O laço acima só varre i >= nsegs, então
		// um índice reocupado ficava com a rl.Music e o WAV (~23MB) de um segmento que não
		// existe mais, vazando até fechar o app. Comparar por CHAVE (que não depende do
		// playhead) libera só o que ficou órfão — um render válido de segmento duplicado
		// sobrevive ao playhead sair de cima dele.
		if spv_orphan(i) do spv_release(i)
		if !uses_spv {
			for s in 0 ..< 2 do if spv[i][s].on { rl.PauseMusicStream(spv[i][s].music); spv[i][s].on = false }
			continue
		}
		sg := &segs[i]
		inside := st.playhead >= sg.start && st.playhead < sg.start + sg.dur
		want := st.playing && (st.drag == .None || audio_edit_drag()) && inside && !sg.muted && !track_muted[sg.track]
		tl_local := clamp(st.playhead - sg.start, 0, sg.dur) // posição no tempo do SEGMENTO
		ci := clamp(int(tl_local / SPV_CHUNK), 0, spv_nchunks(i) - 1)
		e := &spv[i][ci & 1]
		k := spv_key(i, ci)
		// silencia o slot da OUTRA janela (a que acabou de sair de cena)
		if o := &spv[i][1 - (ci & 1)]; o.on { rl.PauseMusicStream(o.music); o.on = false }
		// (re)gera o WAV quando necessário e a interação assentou (não arrastando o slider)
		if want && (!e.ok || e.key != k) && ui_slider_active != 9 && spv_render_idx < 0 &&
		   !(e.bad_key == k && e.bad_n >= SPV_TRIES) {
			spv_request(i, ci, k)
		}
		when DBG_SPV { // 1 linha por segundo por segmento: por que está (ou não) soando
			if want && spv_dbg_tick % 60 == 0 {
				wl := e.ok ? f32(e.music.frameCount) / f32(e.music.stream.sampleRate) : -1
				fmt.eprintfln("[spv] WANT i=%d sp=%.2f dur=%.3f ci=%d/%d e.ok=%v key_eq=%v on=%v play=%v pos=%.2f/%.2f wav=%.2f slider=%d busy=%d",
					i, f64(seg_speed(i)), f64(sg.dur), ci, spv_nchunks(i), e.ok, e.key == k, e.on,
					e.ok ? rl.IsMusicStreamPlaying(e.music) : false,
					f64(e.ok ? rl.GetMusicTimePlayed(e.music) : 0), f64(tl_local - f32(ci)*SPV_CHUNK), f64(wl),
					ui_slider_active, spv_render_idx)
			}
		}
		if want && e.ok && e.key == k {
			// PRÉ-BUSCA da próxima janela no outro slot: renderiza enquanto esta toca,
			// para a troca na borda não ficar muda pelos ~1-2s do ffmpeg.
			if nci := ci + 1; nci < spv_nchunks(i) && tl_local > f32(nci)*SPV_CHUNK - SPV_PRE {
				n  := &spv[i][nci & 1]
				nk := spv_key(i, nci)
				if (!n.ok || n.key != nk) && ui_slider_active != 9 && spv_render_idx < 0 &&
				   !(n.bad_key == nk && n.bad_n >= SPV_TRIES) {
					spv_request(i, nci, nk)
				}
			}
			local := tl_local - f32(ci) * SPV_CHUNK // posição DENTRO da janela (WAV @ 1x)
			if !e.on {
				rl.StopMusicStream(e.music); rl.SeekMusicStream(e.music, local); rl.PlayMusicStream(e.music)
				for _ in 0 ..< 4 do rl.UpdateMusicStream(e.music)
				e.on = true
			} else {
				if !rl.IsMusicStreamPlaying(e.music) do rl.ResumeMusicStream(e.music)
				rl.UpdateMusicStream(e.music)
				if abs(rl.GetMusicTimePlayed(e.music) - local) > 0.3 {
					// re-ADQUIRE (Stop zera a fila): Seek puro deixava os sub-buffers
					// antigos tocando — dessincronia permanente após um hitch, invisível
					// ao próprio check (GetMusicTimePlayed já reportava o alvo)
					rl.StopMusicStream(e.music); rl.SeekMusicStream(e.music, local); rl.PlayMusicStream(e.music)
					for _ in 0 ..< 4 do rl.UpdateMusicStream(e.music)
				}
			}
			rl.SetMusicVolume(e.music, seg_gain(i, st.playhead) * player_vol)
		} else if e.on {
			rl.PauseMusicStream(e.music); e.on = false
		}
	}
	spv_poll()
}
