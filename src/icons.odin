package main

import rl "vendor:raylib"
import "core:math"

// ---------- ícones da interface ----------
// Um só desenho para todos: grade 24×24, traço de 2 unidades com pontas e junções redondas,
// escalado p/ o tamanho pedido. Antes cada botão desenhava o seu à mão (traços de 1.4 a 2px,
// uns preenchidos, outros vazados, branco puro em repouso) e a barra parecia remendada.
// A COR vem do chamador, pelo estado (ver icon_col): apagado em repouso, claro no hover,
// accent quando ligado. Ícone novo = um caso novo aqui, na mesma grade.

Icon :: enum {
	Undo, Redo, Trash, Scissors, Crop, Silence, Captions, CloseGap, Magnet,
	Volume, VolumeMute, Camera, Fullscreen, ExitFullscreen,
}

// caneta: origem do quadro 24×24 na tela, escala e espessura do traço
@(private="file")
Pen :: struct { o: rl.Vector2, k, w: f32, col: rl.Color }

@(private="file")
pt :: proc(p: Pen, x, y: f32) -> rl.Vector2 { return { p.o.x + x * p.k, p.o.y + y * p.k } }

// polilinha (coordenadas da grade, pares x,y) com junções redondas
@(private="file")
line :: proc(p: Pen, xy: ..f32) {
	for i := 0; i + 3 < len(xy); i += 2 {
		rl.DrawLineEx(pt(p, xy[i], xy[i+1]), pt(p, xy[i+2], xy[i+3]), p.w, p.col)
	}
	for i := 0; i + 1 < len(xy); i += 2 do rl.DrawCircleV(pt(p, xy[i], xy[i+1]), p.w / 2, p.col)
}

// arco de traço; ângulos em graus no sentido da tela (0 = direita, 90 = baixo)
@(private="file")
arc :: proc(p: Pen, cx, cy, r, a0, a1: f32) {
	c := pt(p, cx, cy); rr := r * p.k
	rl.DrawRing(c, rr - p.w/2, rr + p.w/2, a0, a1, 24, p.col)
	ends := [2]f32{ a0, a1 }
	for a in ends {
		rad := a * rl.DEG2RAD
		rl.DrawCircleV({ c.x + rr * math.cos(rad), c.y + rr * math.sin(rad) }, p.w / 2, p.col)
	}
}

@(private="file")
circle :: proc(p: Pen, cx, cy, r: f32) {
	rr := r * p.k
	rl.DrawRing(pt(p, cx, cy), rr - p.w/2, rr + p.w/2, 0, 360, 36, p.col)
}

// cor do ícone pelo estado do botão (mesmo critério em toda a interface)
icon_col :: proc(ok: bool, hot: bool, on := false) -> rl.Color {
	if !ok do return DISABLED
	if on do return ACCENT
	return hot ? TEXT : MUTED
}

// desenha `kind` centrado em (cx,cy) num quadrado de `size` px
draw_icon :: proc(kind: Icon, cx, cy, size: f32, col: rl.Color) {
	k := size / 24
	p := Pen{ { cx - size/2, cy - size/2 }, k, max(1.7, 2 * k), col }
	switch kind {
	case .Undo: // seta curva p/ trás
		line(p, 9, 14, 4, 9, 9, 4)
		line(p, 4, 9, 14.5, 9)
		arc(p, 14.5, 14.5, 5.5, -90, 90)
		line(p, 14.5, 20, 11, 20)
	case .Redo:
		line(p, 15, 14, 20, 9, 15, 4)
		line(p, 20, 9, 9.5, 9)
		arc(p, 9.5, 14.5, 5.5, 90, 270)
		line(p, 9.5, 20, 13, 20)
	case .Trash:
		line(p, 3, 6, 21, 6)
		line(p, 5, 6, 5.8, 21, 18.2, 21, 19, 6)
		line(p, 8.5, 6, 8.5, 3, 15.5, 3, 15.5, 6)
		line(p, 10, 10.5, 10, 16.5)
		line(p, 14, 10.5, 14, 16.5)
	case .Scissors:
		circle(p, 6, 6, 3)
		circle(p, 6, 18, 3)
		line(p, 20, 4, 8.12, 15.88)
		line(p, 14.47, 14.48, 20, 20)
		line(p, 8.12, 8.12, 12, 12)
	case .Crop:
		line(p, 6, 2, 6, 18, 22, 18)
		line(p, 18, 22, 18, 6, 2, 6)
	case .Silence: // fala | trecho mudo pontilhado | fala
		line(p, 2.5, 10, 2.5, 14)
		line(p, 6.5, 5, 6.5, 19)
		line(p, 17.5, 5, 17.5, 19)
		line(p, 21.5, 10, 21.5, 14)
		line(p, 10.25, 12, 10.75, 12)
		line(p, 13.25, 12, 13.75, 12)
	case .Captions: // legenda: quadro com duas linhas de texto
		line(p, 3, 5, 21, 5, 21, 19, 3, 19, 3, 5)
		line(p, 7, 11, 9, 11)
		line(p, 13, 11, 17, 11)
		line(p, 7, 15, 11, 15)
		line(p, 15, 15, 17, 15)
	case .CloseGap: // duas setas fechando sobre o vão (eixo pontilhado)
		line(p, 2, 12, 8, 12)
		line(p, 5, 9, 8, 12, 5, 15)
		line(p, 22, 12, 16, 12)
		line(p, 19, 9, 16, 12, 19, 15)
		line(p, 12, 3, 12, 5)
		line(p, 12, 11, 12, 13)
		line(p, 12, 19, 12, 21)
	case .Magnet: // ímã em U com os polos marcados
		line(p, 5, 2, 5, 13)
		arc(p, 12, 13, 7, 0, 180)
		line(p, 19, 13, 19, 2)
		line(p, 2.5, 6.5, 7.5, 6.5)
		line(p, 16.5, 6.5, 21.5, 6.5)
	case .Volume, .VolumeMute:
		line(p, 11, 4.5, 6, 9, 3, 9, 3, 15, 6, 15, 11, 19.5, 11, 4.5)
		if kind == .Volume {
			arc(p, 12, 12, 5, -37, 37)
			arc(p, 13, 12, 9, -45, 45)
		} else {
			line(p, 16, 9, 22, 15)
			line(p, 22, 9, 16, 15)
		}
	case .Camera:
		line(p, 2, 7, 7, 7, 9, 4, 15, 4, 17, 7, 22, 7, 22, 20, 2, 20, 2, 7)
		circle(p, 12, 13.5, 3.5)
	case .Fullscreen:
		line(p, 8, 3, 3, 3, 3, 8)
		line(p, 16, 3, 21, 3, 21, 8)
		line(p, 3, 16, 3, 21, 8, 21)
		line(p, 21, 16, 21, 21, 16, 21)
	case .ExitFullscreen: // cantos virados p/ dentro
		line(p, 3, 8, 8, 8, 8, 3)
		line(p, 16, 3, 16, 8, 21, 8)
		line(p, 3, 16, 8, 16, 8, 21)
		line(p, 21, 16, 16, 16, 16, 21)
	}
}
