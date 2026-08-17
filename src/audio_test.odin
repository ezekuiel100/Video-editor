package main

// Testes da LÓGICA DE JANELA DE ÁUDIO: qual arquivo está aberto em `c.music`
// (head / chunk / OGG completo) e se ele cobre a posição pedida na FONTE.
//
// POR QUE existe: erro aqui falha em SILÊNCIO. Áudio mudo, ou tocando de uma
// posição errada, não levanta erro, não quebra o build e não aparece em nenhum
// outro teste — a mesma razão que levou o export a ser testado como texto (ver
// README). É neste subsistema que nasceram: o clipe que MUTAVA ao dar seek com
// vários vídeos na timeline (guarda `parts_done`), a reabertura do MESMO arquivo
// a cada frame na cauda de um áudio mais curto que o vídeo, e a margem de 0.25s
// que impede o fim do head de ser lido como "fim do clipe".
//
// ================== LIMITE IMPORTANTE AO ADICIONAR CASOS ==================
// Estes testes NÃO inicializam o dispositivo de áudio: montam um `rl.Music`
// FALSO, preenchendo só frameCount/sampleRate (que é tudo que a aritmética de
// janela lê). Logo, só podem exercitar os caminhos que retornam ANTES da
// primeira chamada ao raylib:
//
//   audio_clock_ok           -> puro, qualquer caso serve
//   audio_full_window_ready  -> puro, qualquer caso serve
//   audio_hush_cooling       -> puro
//   audio_window_end / audio_in_open_window -> puros
//   audio_adopt_or_request   -> só caminhos que NÃO chegam no corpo do chunk_request
//   try_part_open            -> só até o `if c.has_audio { rl.UnloadMusicStream }`
//   try_chunk_open           -> idem
//   chunk_request            -> só os dois early-returns (o resto SOBE UM FFMPEG)
//
// Um caso que "vazar" pro corpo dessas três últimas vai chamar o raylib num
// handle falso. Ao escrever um caso novo, confirme que ele cai num retorno
// antecipado — os testes abaixo dizem em qual, no nome ou no comentário.
//
//   odin test src -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
//
// (t_reset/t_feq vêm de segs_test.odin — mesmo pacote)

import "core:testing"
import "base:intrinsics"

T_RATE :: 48000 // taxa do rl.Music falso; só precisa ser != 0 (a lógica usa a razão)

// monta clips[0] com uma janela de áudio ABERTA: `cover` segundos a partir de
// `base` (segundos na FONTE). base 0 = head ou OGG completo; base > 0 = chunk.
t_aud :: proc(dur, base, cover: f32) -> ^Clip {
	c := &clips[0]
	c.dur = dur
	c.has_audio = true
	c.music_base = base
	c.music.stream.sampleRate = T_RATE
	c.music.frameCount = u32(cover * T_RATE)
	return c
}

// ---------------------------------------------------------------- audio_clock_ok

@(test)
hush_cooling_vale_so_o_frame_atual :: proc(t: ^testing.T) {
	t_reset()
	audio_hush_at = g_frame_no
	testing.expect(t, audio_hush_cooling(), "no frame do hush o Play novo ainda não pode entrar")
	g_frame_no += 1
	testing.expect(t, !audio_hush_cooling(), "no frame seguinte o mixer já largou o buffer velho")
}

@(test)
clock_sem_audio_nunca_vale :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 100)
	c.has_audio = false // extração ainda não chegou (ou music_open falhou)
	testing.expect(t, !audio_clock_ok(c, 10), "sem has_audio não há relógio, mesmo com o resto preenchido")
}

@(test)
clock_dentro_da_janela_base_zero :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 60) // head de 60s num vídeo de 100s
	testing.expect(t, audio_clock_ok(c, 0),  "o começo do head vale")
	testing.expect(t, audio_clock_ok(c, 30), "o meio do head vale")
	testing.expect(t, !audio_clock_ok(c, 80), "além do head não há relógio (cai no relógio de parede)")
}

@(test)
clock_margem_de_025_no_fim :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 60)
	// a margem existe porque o fim do stream era interpretado como FIM DO CLIPE:
	// o playback pulava pro final em vez de seguir mudo até o áudio completo chegar
	testing.expect(t, audio_clock_ok(c, 59.7),  "59.7 ainda está dentro (fim 60 - 0.25)")
	testing.expect(t, !audio_clock_ok(c, 59.8), "59.8 já está na margem morta do fim")
	testing.expect(t, !audio_clock_ok(c, 60),   "o fim exato não vale")
}

@(test)
clock_chunk_tem_offset_na_fonte :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 600, 300) // chunk cobrindo 600..900s de um vídeo de 1h
	testing.expect(t, !audio_clock_ok(c, 300), "antes da base do chunk não há relógio")
	testing.expect(t, audio_clock_ok(c, 600),  "a base do chunk é inclusiva")
	testing.expect(t, audio_clock_ok(c, 890),  "dentro do chunk vale")
	testing.expect(t, !audio_clock_ok(c, 900), "depois do fim do chunk, não")
}

// ------------------------------------------------------- audio_full_window_ready

@(test)
full_window_exige_o_ogg_no_disco :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 100) // stream base-0 cobrindo o vídeo inteiro
	intrinsics.atomic_store(&c.parts_done, 0)
	// REGRESSÃO: sem esta guarda o set_play_clip descarregava este stream (que
	// FUNCIONA) e o music_open falhava no _full.ogg ainda sendo gerado ->
	// has_audio=false = clipe MUDO ao dar seek. Aparecia com vários vídeos porque
	// os parts_worker concorrentes atrasam o ogg do clipe pra onde você pula.
	testing.expect(t, !audio_full_window_ready(c), "sem o _full.ogg pronto NÃO se troca a janela")
	intrinsics.atomic_store(&c.parts_done, 1)
	testing.expect(t, audio_full_window_ready(c), "com o ogg pronto e o stream cobrindo tudo, troca")
}

@(test)
full_window_recusa_head_e_chunk :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 60) // head: base 0, mas cobre só 60 de 100s
	intrinsics.atomic_store(&c.parts_done, 1)
	testing.expect(t, !audio_full_window_ready(c), "head não é a janela completa (curto demais)")

	c2 := t_aud(100, 40, 100) // chunk: cobre bastante, mas não começa na origem
	intrinsics.atomic_store(&c2.parts_done, 1)
	testing.expect(t, !audio_full_window_ready(c2), "chunk não é a janela completa (music_base != 0)")

	c3 := t_aud(100, 0, 100)
	intrinsics.atomic_store(&c3.parts_done, 1)
	c3.has_audio = false
	testing.expect(t, !audio_full_window_ready(c3), "sem stream aberto não há janela a considerar")
}

@(test)
full_window_tolera_1s_a_menos :: proc(t: ^testing.T) {
	t_reset()
	// o áudio extraído costuma sair alguns décimos mais curto que a duração do
	// vídeo; a folga de 1s evita classificar o completo como "head"
	c := t_aud(100, 0, 99.5)
	intrinsics.atomic_store(&c.parts_done, 1)
	testing.expect(t, audio_full_window_ready(c), "0.5s a menos ainda é a janela completa")
	c2 := t_aud(100, 0, 98.5)
	intrinsics.atomic_store(&c2.parts_done, 1)
	testing.expect(t, !audio_full_window_ready(c2), "1.5s a menos já não é")
}

// ---------------------------------------------------------------- try_part_open
// (todos os casos caem num retorno ANTECIPADO — nenhum chega ao rl.UnloadMusicStream)

@(test)
part_open_relogio_ok_nao_mexe_em_nada :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 60)
	intrinsics.atomic_store(&c.parts_done, 1)
	base_antes := c.music_base
	testing.expect(t, try_part_open(c, 30), "já há relógio em 30s: nada a trocar")
	testing.expect(t, c.music_base == base_antes, "e a janela aberta continua a mesma")
}

@(test)
part_open_sem_o_ogg_pronto_desiste :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 60)
	intrinsics.atomic_store(&c.parts_done, 0)
	testing.expect(t, !try_part_open(c, 80), "fora do head e sem o ogg pronto: desiste (o chamador pede chunk)")
	testing.expect(t, c.has_audio, "e NÃO descarta o stream que ainda serve p/ o resto do clipe")
}

@(test)
part_open_cache_base_zero_nao_reabre_o_mesmo_arquivo :: proc(t: ^testing.T) {
	t_reset()
	// clipe de cache (não-streaming) cujo ÁUDIO é mais curto que o vídeo: na cauda
	// o relógio não vale, mas não existe janela melhor. Sem esta guarda o
	// try_part_open descarregava e reabria o MESMO arquivo a cada frame.
	c := t_aud(100, 0, 90)
	c.streaming = false
	c.music_full = true // o que está aberto É o _full.ogg (só ele cobre 90s de um head de 30)
	intrinsics.atomic_store(&c.parts_done, 1)
	testing.expect(t, !try_part_open(c, 95), "na cauda não há o que trocar: já é a única janela")
	testing.expect(t, c.has_audio, "e o stream segue aberto (não foi descarregado)")
}

@(test)
part_open_streaming_audio_curto_nao_reabre :: proc(t: ^testing.T) {
	t_reset()
	// o mesmo caso do teste acima, mas STREAMING: vídeo de 100s cujo áudio acaba aos 60
	// (o mic parou antes do fim). O completo mede 60 < dur-0.5, então o teste por DURAÇÃO
	// o confundia com o head e trocava o arquivo por ele mesmo — Unload+Load de um OGG de
	// ~90MB a cada frame da cauda, com o preview picotando junto. Quem responde agora é a
	// identidade do stream (music_full), não o tamanho.
	c := t_aud(100, 0, 60)
	c.streaming = true
	c.music_full = true
	intrinsics.atomic_store(&c.parts_done, 1)
	testing.expect(t, !try_part_open(c, 80), "já é o completo: não há janela melhor, mesmo sem cobrir 80s")
	testing.expect(t, c.has_audio, "e o stream NÃO é descarregado")
}

@(test)
part_open_head_aberto_sobe_para_o_completo :: proc(t: ^testing.T) {
	t_reset()
	// contraprova do teste acima: com o HEAD aberto (music_full=false) e o ogg pronto, a
	// troca DEVE acontecer. O guard antigo por !c.streaming barrava esta subida nos clipes
	// de cache — ficavam presos no head de 30s com o completo pronto no disco.
	c := t_aud(100, 0, 30)
	c.streaming = false
	c.music_full = false
	intrinsics.atomic_store(&c.parts_done, 1)
	// não dá p/ ir além (o music_open real toca o disco); basta constatar que NÃO houve o
	// retorno antecipado: o stream foi descarregado para dar lugar ao completo
	_ = try_part_open(c, 80)
	testing.expect(t, !c.has_audio, "o head saiu de cena p/ o completo entrar")
}

@(test)
part_open_streaming_ja_no_completo_desiste :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(100, 0, 100) // streaming, já com o OGG completo aberto
	c.streaming = true
	c.music_full = true
	intrinsics.atomic_store(&c.parts_done, 1)
	// 99.9 cai na margem morta de 0.25s, então o relógio não vale — mas a janela
	// aberta JÁ é a completa: trocar não melhoraria nada
	testing.expect(t, !try_part_open(c, 99.9), "já é o completo: não há janela melhor")
	testing.expect(t, c.has_audio, "stream preservado")
}

// --------------------------------------------------------------- try_chunk_open
// (idem: só retornos antecipados)

@(test)
chunk_open_relogio_ok_curto_circuita :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 0, 60)
	testing.expect(t, try_chunk_open(c, 10), "com relógio válido nem olha o chunk")
}

@(test)
chunk_open_ignora_extracao_em_voo_ou_falha :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 0, 60)
	c.chunk_busy = true
	testing.expect(t, !try_chunk_open(c, 1000), "worker ainda extraindo: não adota")

	c.chunk_busy = false
	intrinsics.atomic_store(&c.chunk_done, true)
	intrinsics.atomic_store(&c.chunk_ok, false) // ffmpeg falhou
	testing.expect(t, !try_chunk_open(c, 1000), "extração que falhou não vira janela")
}

@(test)
chunk_open_so_adota_se_cobre_a_posicao :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 0, 60)
	c.chunk_busy = false
	intrinsics.atomic_store(&c.chunk_done, true)
	intrinsics.atomic_store(&c.chunk_ok, true)
	c.chunk_base = 600 // chunk pronto cobrindo 600..900 (CHUNK_SECS)
	testing.expect(t, !try_chunk_open(c, 500), "posição ANTES do chunk no bolso: não serve")
	testing.expect(t, !try_chunk_open(c, 600 + CHUNK_SECS), "posição DEPOIS do chunk: não serve")
	// um caso DENTRO da janela seguiria p/ o music_open — fora do alcance destes
	// testes (ver o aviso no topo do arquivo)
}

// ---------------------------------------------------------------- chunk_request
// (só os dois early-returns: o corpo sobe um ffmpeg de verdade)

@(test)
chunk_request_nao_reempilha_pedido :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 0, 60)
	c.chunk_busy = true
	c.chunk_req = 123
	chunk_request(c, 2000)
	testing.expect(t, c.chunk_req == 123, "com worker no ar o pedido novo é ignorado")
	testing.expect(t, c.chunk_thr == nil, "e nenhuma thread nova é criada")
}

@(test)
chunk_request_nao_repete_o_que_ja_esta_no_bolso :: proc(t: ^testing.T) {
	t_reset()
	c := t_aud(3600, 0, 60)
	c.chunk_busy = false
	intrinsics.atomic_store(&c.chunk_done, true)
	intrinsics.atomic_store(&c.chunk_ok, true)
	c.chunk_base = 600
	c.chunk_req = 599
	chunk_request(c, 700) // 700 está dentro de 600..900
	testing.expect(t, c.chunk_req == 599, "o chunk no bolso já cobre: não pede de novo")
	testing.expect(t, !c.chunk_busy, "e não marca worker no ar")
}

@(test)
chunk_cobertura_real_manda_no_lugar_da_nominal :: proc(t: ^testing.T) {
	t_reset()
	// chunk pedido em 600 com `-t 300`, mas o áudio da fonte acaba em 631: o ffmpeg grava
	// só 31s. Pela faixa NOMINAL (600..900) o ponto 700 parecia coberto, e o try_chunk_open
	// devolvia true sem cobrir nada — o chamador nunca pedia outro chunk e o trecho ficava
	// mudo, reabrindo o mesmo WAV a cada frame. Quem manda agora é a cobertura MEDIDA.
	// (só os retornos antecipados: passar deles abre o arquivo / sobe um ffmpeg)
	c := t_aud(3600, 0, 60)
	c.chunk_busy = false
	intrinsics.atomic_store(&c.chunk_done, true)
	intrinsics.atomic_store(&c.chunk_ok, true)
	c.chunk_base = 600
	c.chunk_meas = true; c.chunk_cov = 31 // medido ao abrir: cobre 600..631, não 600..900
	testing.expect(t, !try_chunk_open(c, 700), "700 está fora da cobertura REAL: não adota")
	testing.expect(t, c.has_audio, "e não descarrega o stream aberto para reabrir o mesmo arquivo")
	c.chunk_req = 599
	chunk_request(c, 610) // 610 está dentro da cobertura real: segue valendo o atalho
	testing.expect(t, c.chunk_req == 599, "dentro da cobertura real continua sendo 'já no bolso'")
	testing.expect(t, !c.chunk_busy, "e não marca worker no ar")
}

@(test)
chunk_request_nao_repete_trecho_provado_vazio :: proc(t: ^testing.T) {
	t_reset()
	// um chunk extraído em 600s voltou só com cabeçalho: está PROVADO que o áudio da fonte
	// acaba antes daí. Sem registrar isso, o chunk_request pedia o mesmo trecho de novo a
	// cada ciclo — um ffmpeg por segundo, para sempre, enquanto o playhead ficasse na cauda.
	// (só o retorno antecipado: passar dele sobe um ffmpeg)
	c := t_aud(3600, 0, 60)
	c.chunk_busy = false
	c.aud_end = 600
	c.chunk_req = 599
	chunk_request(c, 700)
	testing.expect(t, c.chunk_req == 599, "não pede áudio onde já se provou não haver")
	testing.expect(t, !c.chunk_busy, "e não sobe worker nenhum")
	testing.expect(t, c.chunk_thr == nil, "nenhuma thread criada")
}

// ------------------------------------------------------- audio_adopt_or_request
// (só retornos antecipados — nenhum chega no corpo do chunk_request)

@(test)
adopt_nao_pede_chunk_na_cauda_do_completo :: proc(t: ^testing.T) {
	t_reset()
	// REGRESSÃO: a timeline pedia chunk a cada frame nos 0.25s finais (audio_clock_ok
	// falha), a adoção trocava o OGG pelo WAV da cauda e o áudio picotava com o
	// vídeo já no último frame.
	c := t_aud(60, 0, 60)
	c.music_full = true
	c.streaming = false
	intrinsics.atomic_store(&c.parts_done, 1)
	c.chunk_req = 42
	testing.expect(t, audio_in_open_window(c, 59.9), "59.9 ainda é a janela aberta (margem morta)")
	testing.expect(t, !audio_adopt_or_request(c, 59.9), "na cauda não há relógio")
	testing.expect(t, c.chunk_req == 42, "e NÃO encomenda um chunk do fim")
	testing.expect(t, !c.chunk_busy, "nenhum worker sobe")
	testing.expect(t, c.has_audio, "o stream completo segue aberto")
}

@(test)
adopt_nao_pede_chunk_alem_do_audio_curto :: proc(t: ^testing.T) {
	t_reset()
	// áudio acaba aos 90s dum vídeo de 100s: além do EOF não existe janela melhor
	c := t_aud(100, 0, 90)
	c.music_full = true
	intrinsics.atomic_store(&c.parts_done, 1)
	c.chunk_req = 7
	testing.expect(t, !audio_adopt_or_request(c, 95), "além do áudio: desiste")
	testing.expect(t, c.chunk_req == 7, "não pede a cauda vazia")
	testing.expect(t, !c.chunk_busy)
}

@(test)
adopt_nao_pede_chunk_na_cauda_do_head :: proc(t: ^testing.T) {
	t_reset()
	// head de 60s ainda no ar, OGG incompleto: os 0.25s finais do HEAD não podem
	// disparar um chunk do mesmo trecho (o prefetch de -15s já cuida do próximo).
	c := t_aud(3600, 0, 60)
	c.music_full = false
	c.streaming = true
	intrinsics.atomic_store(&c.parts_done, 0)
	c.chunk_req = 11
	testing.expect(t, !audio_clock_ok(c, 59.9), "59.9 está na margem morta do head")
	testing.expect(t, !audio_adopt_or_request(c, 59.9), "sem janela melhor agora")
	testing.expect(t, c.chunk_req == 11, "não extrai a cauda do head")
	testing.expect(t, !c.chunk_busy)
}
