package main

// MODO CAPTURA:  editor.exe -shot saida.png ["caminho\video.mp4"]
//
// Abre o editor (opcionalmente importando um vídeo direto na timeline), espera a
// interface assentar, grava um PNG da janela e fecha. Serve p/ comparar o visual
// ANTES/DEPOIS de mexer em layout/tema sem depender de print manual.

import "core:fmt"
import "core:os"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

shot_checked: bool
shot_out:     cstring // "" = modo desligado
shot_t0:      f64

SHOT_WAIT :: 5.0 // s: tempo p/ import + miniaturas + onda aparecerem

// chamada 1x por frame ANTES do EndDrawing (lê o back buffer já desenhado)
shot_frame :: proc() {
	if !shot_checked {
		shot_checked = true
		for a, i in os.args do if a == "-shot" && i + 1 < len(os.args) {
			shot_out = cstring(raw_data(fmt.aprintf("%s\x00", os.args[i + 1])))
			if i + 2 < len(os.args) do import_media(os.args[i + 2], true)
			shot_t0 = rl.GetTime()
		}
	}
	if shot_out == nil || should_close do return
	if rl.GetTime() - shot_t0 < SHOT_WAIT do return
	// -shotsel: seleciona o 1º clipe (mostra o inspetor preenchido) e captura no frame seguinte
	for a in os.args do if a == "-shotsel" && selected < 0 && nsegs > 0 { selected = 0; return }
	rlgl.DrawRenderBatchActive() // o lote ainda não foi pro framebuffer (só no EndDrawing)
	rl.TakeScreenshot(shot_out)
	should_close = true
}
