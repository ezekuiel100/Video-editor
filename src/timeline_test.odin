package main

import "core:testing"

@(test)
timeline_scroll_preserva_ponto_agarrado :: proc(t: ^testing.T) {
	// Track x=150, thumb x=350, width=200, travel=600, scroll=400.
	// Agarrar qualquer ponto deve manter a posição; mover 30px avança 60s.
	grabs := [?]f32{0, 10, 100, 190, 200}
	for grab in grabs {
		testing.expect(t, t_feq(tl_scroll_from_grab(350 + grab, 150, grab, 600, 1200), 400))
		testing.expect(t, t_feq(tl_scroll_from_grab(380 + grab, 150, grab, 600, 1200), 460))
	}
}

@(test)
timeline_scroll_limites :: proc(t: ^testing.T) {
	testing.expect(t, tl_scroll_from_grab(-500, 150, 30, 600, 1200) == 0)
	testing.expect(t, tl_scroll_from_grab(2000, 150, 30, 600, 1200) == 1200)
	testing.expect(t, tl_scroll_from_grab(350, 150, 30, 0, 1200) == 0)
}
