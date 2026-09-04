package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

// --- EFEITO: distorção radial (bulge/pinch) para o vídeo ---
bulge_shader: rl.Shader
bulge_ok: bool
bulge_loc_uv0, bulge_loc_uv1, bulge_loc_center, bulge_loc_strength, bulge_loc_radius, bulge_loc_aspect: i32
fx_loc_bright, fx_loc_contrast, fx_loc_satur, fx_loc_look, fx_loc_vignette, fx_loc_temp: i32 // uniforms de COR
fx_loc_rgb: i32 // uniform da separação RGB
fx_loc_wipe_edge, fx_loc_wipe_feather, fx_loc_wipe_inv, fx_loc_wipe_kind: i32 // transições de máscara
fx_loc_kind, fx_loc_amt, fx_loc_time, fx_loc_ang: i32 // clipes de efeito de faixa (além de distorção/RGB)
BULGE_R_DEF :: f32(0.5) // raio padrão do efeito (quando bulge_r==0)
WOBBLE_HZ_DEF :: f32(2) // frequência padrão do wobble (Hz, quando wobble_speed==0)
// desloca a coord de textura em direção ao (bulge>0) ou p/ longe do (bulge<0) centro,
// com queda suave até a borda do raio → amplia/aperta uma região circular (efeito "rosto
// inflado" dos memes). Trabalha em coords LOCAIS da sub-região amostrada (respeita crop),
// e clampa a amostragem à região p/ não vazar p/ vizinhos no atlas.
BULGE_FS : cstring : `#version 330
in vec2 fragTexCoord; in vec4 fragColor;
uniform sampler2D texture0; uniform vec4 colDiffuse;
uniform vec2 uv0;       // canto sup-esq da região amostrada (coords de textura)
uniform vec2 uv1;       // canto inf-dir
uniform vec2 center;    // centro do efeito em [0,1] LOCAL da região
uniform float strength; // >0 infla (bulge), <0 aperta (pinch)
uniform float radius;   // raio do efeito [0..1] local
uniform float aspect;   // largura/altura da região exibida (efeito circular)
uniform float bright;   // COR: brilho somado (-1..1)
uniform float contrast; // COR: contraste (1 = neutro)
uniform float satur;    // COR: saturação (1 = neutro)
uniform float look;     // COR: 0 nenhum | 1 P&B | 2 sépia | 3 inverter
uniform float vignette; // COR: vinheta 0..1
uniform float temp;     // COR: temperatura -1(frio)..1(quente)
uniform vec2  rgb;      // EFEITO: separação RGB (deslocamento em coords de textura; 0 = desligado)
uniform float wipeEdge;    // progresso 0..1 da máscara (orgânico / wipe / íris)
uniform float wipeFeather; // 0 = desligado; maciez da fumaça/tinta (orgânico)
uniform float wipeInv;     // 1 = clipe que SAI (máscara invertida)
uniform float wipeKind;    // 0=off/orgânico | 2..5 wipe L/R/U/D | 10 íris | 18 relógio
uniform float fxKind;      // 2 pixel | 3 blur | 4 grain | 5 mirror | 6 sharp | 7 spot | 8 shake | 9 poster | 10 invert | 11 wave | 12 hue | 13 glow | 14 kaleido | 15 scan | 16 edge
uniform float fxAmt;       // intensidade 0..1 do efeito de faixa
uniform float fxTime;      // tempo (s) p/ granulação/tremor
uniform float fxAng;       // Espelhar: <0.5 horizontal, senão vertical
float vn(vec2 p, vec2 seed) {
    vec2 i = floor(p); vec2 f = fract(p);
    f = f*f*(3.0-2.0*f);
    float n00 = fract(sin(dot(i,               seed)) * 43758.5453);
    float n10 = fract(sin(dot(i+vec2(1.0,0.0), seed)) * 43758.5453);
    float n01 = fract(sin(dot(i+vec2(0.0,1.0), seed)) * 43758.5453);
    float n11 = fract(sin(dot(i+vec2(1.0,1.0), seed)) * 43758.5453);
    return mix(mix(n00,n10,f.x), mix(n01,n11,f.x), f.y);
}
float fbm3(vec2 p) {
    return vn(p, vec2(127.1, 311.7))*0.55
         + vn(p*2.07, vec2(269.5, 183.3))*0.30
         + vn(p*4.13, vec2(74.2, 91.7))*0.15;
}
out vec4 finalColor;
void main() {
    vec2 span = uv1 - uv0;
    vec2 local = (fragTexCoord - uv0) / span;   // [0,1] dentro da região
    vec2 d = local - center;
    vec2 da = vec2(d.x*aspect, d.y);            // distância corrigida p/ ser circular
    float dist = length(da);
    vec2 uv = local;
    if (dist < radius) {
        float pct = 1.0 - dist/radius;          // 1 no centro -> 0 na borda
        float amt = strength*pct*pct;           // suave (zera na borda)
        uv = local - d*amt;                     // amt>0: amostra p/ o centro => amplia
    }
    if (fxKind > 4.5 && fxKind < 5.5) {           // ESPELHAR: dobra a metade
        if (fxAng < 0.5) uv.x = 0.5 - abs(uv.x - 0.5);
        else             uv.y = 0.5 - abs(uv.y - 0.5);
    }
    if (fxKind > 7.5 && fxKind < 8.5) {           // TREMOR: desloca o quadro
        uv += vec2(sin(fxTime*23.0), cos(fxTime*17.0)) * fxAmt * 0.028;
    }
    if (fxKind > 10.5 && fxKind < 11.5) {          // ONDA
        uv.x += sin(uv.y * mix(6.0, 18.0, fxAmt) + fxTime * 6.2832) * fxAmt * 0.045;
        uv.y += cos(uv.x * 9.0 + fxTime * 4.0) * fxAmt * 0.022;
    }
    if (fxKind > 13.5 && fxKind < 14.5) {          // CALEIDOSCÓPIO
        vec2 p = uv - vec2(0.5);
        float a = atan(p.y, p.x);
        float rr = length(p);
        float slices = mix(4.0, 12.0, clamp(fxAmt, 0.0, 1.0));
        float sa = 6.2831853 / slices;
        a = mod(a, sa);
        a = abs(a - sa * 0.5);
        uv = vec2(cos(a), sin(a)) * rr + vec2(0.5);
    }
    if (fxKind > 1.5 && fxKind < 2.5) {           // PIXELIZAR
        float nPix = mix(90.0, 8.0, clamp(fxAmt, 0.0, 1.0));
        uv = (floor(uv * nPix) + 0.5) / nPix;
    }
    vec2 tex = uv0 + clamp(uv, 0.0, 1.0)*span;
    vec4 src;
    vec3 c;
    if (fxKind > 2.5 && fxKind < 3.5) {           // DESFOQUE 3×3
        vec2 o = vec2(fxAmt * 0.012 / max(aspect, 0.2), fxAmt * 0.012);
        vec3 acc = vec3(0.0);
        acc += texture(texture0, uv0 + clamp(uv + vec2(-o.x,-o.y), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2( 0.0,-o.y), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2( o.x,-o.y), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2(-o.x, 0.0), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, tex).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2( o.x, 0.0), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2(-o.x, o.y), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2( 0.0, o.y), 0.0, 1.0)*span).rgb;
        acc += texture(texture0, uv0 + clamp(uv + vec2( o.x, o.y), 0.0, 1.0)*span).rgb;
        c = acc / 9.0;
        src = vec4(c, texture(texture0, tex).a);
    } else {
        src = texture(texture0, tex);
        c = src.rgb;
    }
    if (rgb.x != 0.0 || rgb.y != 0.0) {           // SEPARAÇÃO RGB: R e B amostrados deslocados
        c.r = texture(texture0, clamp(tex + rgb, uv0, uv1)).r;
        c.b = texture(texture0, clamp(tex - rgb, uv0, uv1)).b;
    }
    // ordem casa com o filtro eq do ffmpeg (export): contraste -> brilho -> temp -> saturação
    c = (c - 0.5) * contrast + 0.5;
    c += bright;
    c.r += temp*0.12; c.b -= temp*0.12;           // temperatura (quente>0: +vermelho, -azul)
    float g = dot(c, vec3(0.299, 0.587, 0.114));  // luma
    c = mix(vec3(g), c, satur);
    if (look > 0.5 && look < 1.5) {               // P&B
        c = vec3(dot(c, vec3(0.299, 0.587, 0.114)));
    } else if (look > 1.5 && look < 2.5) {        // sépia
        float y = dot(c, vec3(0.299, 0.587, 0.114));
        c = vec3(y*1.07, y*0.74, y*0.43);
    } else if (look > 2.5) {                       // inverter
        c = vec3(1.0) - c;
    }
    if (vignette > 0.001) {                        // escurece as bordas
        vec2 vd = local - vec2(0.5);
        float rr = length(vec2(vd.x*aspect, vd.y));
        float v = smoothstep(0.75, 0.30, rr);      // 1 no centro -> 0 nas quinas
        c *= mix(1.0, v, vignette);
    }
    if (fxKind > 5.5 && fxKind < 6.5) {            // NITIDEZ: unsharp simples
        float s = 0.004;
        vec3 nb = texture(texture0, uv0 + clamp(uv+vec2(s,0.0), 0.0, 1.0)*span).rgb
                + texture(texture0, uv0 + clamp(uv-vec2(s,0.0), 0.0, 1.0)*span).rgb
                + texture(texture0, uv0 + clamp(uv+vec2(0.0,s), 0.0, 1.0)*span).rgb
                + texture(texture0, uv0 + clamp(uv-vec2(0.0,s), 0.0, 1.0)*span).rgb;
        vec3 bl = nb * 0.25;
        c = c + (c - bl) * fxAmt * 1.8;
    }
    if (fxKind > 8.5 && fxKind < 9.5) {            // POSTERIZAR
        float nPos = mix(12.0, 3.0, clamp(fxAmt, 0.0, 1.0));
        c = floor(c * nPos + 0.5) / nPos;
    }
    if (fxKind > 3.5 && fxKind < 4.5) {            // GRANULAÇÃO
        float nGr = fract(sin(dot(local * vec2(973.1, 617.3) + fxTime * 51.0, vec2(12.9898, 78.233))) * 43758.5453);
        c += (nGr - 0.5) * fxAmt * 0.45;
    }
    if (fxKind > 6.5 && fxKind < 7.5) {            // HOLOFOTE: escurece fora do raio
        vec2 sd = local - center;
        float sdist = length(vec2(sd.x*aspect, sd.y));
        float sm = smoothstep(radius, radius * 0.35, sdist);
        c *= mix(1.0 - fxAmt * 0.92, 1.0, sm);
    }
    if (fxKind > 9.5 && fxKind < 10.5) {           // INVERTER
        c = mix(c, vec3(1.0) - c, clamp(fxAmt, 0.0, 1.0));
    }
    if (fxKind > 11.5 && fxKind < 12.5) {          // MATIZ
        float ang = fxAmt * 6.2831853;
        float cosA = cos(ang); float sinA = sin(ang);
        mat3 hueM = mat3(
            vec3(0.213+0.787*cosA-0.213*sinA, 0.213-0.213*cosA+0.143*sinA, 0.213-0.213*cosA-0.787*sinA),
            vec3(0.715-0.715*cosA-0.715*sinA, 0.715+0.285*cosA+0.140*sinA, 0.715-0.715*cosA+0.715*sinA),
            vec3(0.072-0.072*cosA+0.928*sinA, 0.072-0.072*cosA-0.283*sinA, 0.072+0.928*cosA+0.072*sinA)
        );
        c = clamp(hueM * c, 0.0, 1.0);
    }
    if (fxKind > 12.5 && fxKind < 13.5) {          // BRILHO (glow)
        vec2 o = vec2(0.012 / max(aspect, 0.2), 0.012);
        vec3 acc = texture(texture0, uv0 + clamp(uv + vec2(-o.x,0.0), 0.0, 1.0)*span).rgb
                 + texture(texture0, uv0 + clamp(uv + vec2( o.x,0.0), 0.0, 1.0)*span).rgb
                 + texture(texture0, uv0 + clamp(uv + vec2(0.0,-o.y), 0.0, 1.0)*span).rgb
                 + texture(texture0, uv0 + clamp(uv + vec2(0.0, o.y), 0.0, 1.0)*span).rgb;
        vec3 bloom = max(acc * 0.25 - vec3(0.35), vec3(0.0));
        c += bloom * fxAmt * 1.6;
    }
    if (fxKind > 14.5 && fxKind < 15.5) {          // VARREDURA
        float dens = mix(90.0, 240.0, clamp(fxAmt, 0.0, 1.0));
        float sl = 0.45 + 0.55 * abs(sin(local.y * dens + fxTime * 6.0));
        c *= mix(1.0, sl, clamp(fxAmt, 0.0, 1.0) * 0.85);
        c.g *= 1.0 + fxAmt * 0.04;
    }
    if (fxKind > 15.5 && fxKind < 16.5) {          // CONTORNO
        float s = 0.004;
        vec3 n1 = texture(texture0, uv0 + clamp(uv+vec2(s,0.0), 0.0, 1.0)*span).rgb;
        vec3 n2 = texture(texture0, uv0 + clamp(uv-vec2(s,0.0), 0.0, 1.0)*span).rgb;
        vec3 n3 = texture(texture0, uv0 + clamp(uv+vec2(0.0,s), 0.0, 1.0)*span).rgb;
        vec3 n4 = texture(texture0, uv0 + clamp(uv-vec2(0.0,s), 0.0, 1.0)*span).rgb;
        float eg = length(n1 - n2) + length(n3 - n4);
        c = mix(c, vec3(eg * 1.8), clamp(fxAmt, 0.0, 1.0));
    }
    c = clamp(c, 0.0, 1.0);
    float a = src.a;
    if (wipeKind > 1.5) {
        float e = clamp(wipeEdge, 0.0, 1.0);
        float f = 0.022;
        float m = 1.0;
        if (wipeKind < 2.5) {              // wipe esquerda: B visível em x < e
            m = 1.0 - smoothstep(e - f, e + f, local.x);
        } else if (wipeKind < 3.5) {       // wipe direita
            m = smoothstep((1.0 - e) - f, (1.0 - e) + f, local.x);
        } else if (wipeKind < 4.5) {       // wipe cima
            m = 1.0 - smoothstep(e - f, e + f, local.y);
        } else if (wipeKind < 5.5) {       // wipe baixo
            m = smoothstep((1.0 - e) - f, (1.0 - e) + f, local.y);
        } else if (wipeKind < 10.5) {      // íris: círculo que cresce do centro
            vec2 dd = local - vec2(0.5);
            float rr = length(vec2(dd.x * aspect, dd.y));
            float rad = e * length(vec2(0.5 * aspect, 0.5));
            m = 1.0 - smoothstep(rad - 0.03, rad + 0.03, rr);
        } else {                           // relógio: varre em torno do centro
            float ang = atan(local.y - 0.5, local.x - 0.5);
            float u = fract(ang / 6.2831853 + 0.25);
            m = 1.0 - smoothstep(e - 0.02, e + 0.02, u);
        }
        if (wipeInv > 0.5) m = 1.0 - m;
        a *= m;
    } else if (wipeFeather > 0.001) {
        // Wipe de tinta/fumaça (Filmora): máscara luma orgânica. Manchas escuras
        // revelam primeiro — a imagem some por partes, sem círculo e sem fade limpo.
        vec2 q = local * vec2(2.55, 2.05);
        float n1 = fbm3(q);
        q += vec2(n1, fbm3(q + vec2(5.2, 1.4))) * 0.48;
        float n2 = fbm3(q * 1.65);
        q += vec2(n2, n1) * 0.28;
        float ink = smoothstep(0.22, 0.78, fbm3(q));
        float s = max(wipeFeather, 0.09);
        float t = wipeEdge * (1.0 + 2.0*s) - s;
        float m = smoothstep(ink - s, ink + s, t);
        if (wipeInv > 0.5) m = 1.0 - m;
        a *= m;
    }
    finalColor = vec4(c, a)*colDiffuse*fragColor;
}`

// força efetiva do bulge no tempo local `t` (s): base + oscilação do wobble. Usado no
// preview (força passada ao shader) E na geração dos mapas do export — MESMA fórmula.
bulge_at :: proc(sg: Seg, t: f32) -> f32 {
	if abs(sg.wobble) < 0.0001 do return sg.bulge
	hz := sg.wobble_speed <= 0 ? WOBBLE_HZ_DEF : sg.wobble_speed
	return sg.bulge + sg.wobble * math.sin(t * 2*math.PI * hz)
}
// o efeito está ativo (estático OU animado)?
bulge_active :: proc(sg: Seg) -> bool { return abs(sg.bulge) > 0.001 || abs(sg.wobble) > 0.001 }
// algum efeito de COR ativo? (qualquer campo fx_* != neutro)
color_active :: proc(sg: Seg) -> bool {
	return abs(sg.fx_bright) > 0.001 || abs(sg.fx_contrast) > 0.001 || abs(sg.fx_satur) > 0.001 ||
	       sg.fx_look > 0.5 || sg.fx_vignette > 0.001 || abs(sg.fx_temp) > 0.001
}
// qualquer efeito (distorção OU cor) ativo? -> liga o shader no draw
fx_any :: proc(sg: Seg) -> bool { return bulge_active(sg) || color_active(sg) }

// --- modal "Cortar e Ampliar" (estilo NLE): botão na toolbar da timeline abre um
// modal com o frame do clipe + retângulo arrastável. Reaproveita os campos crop_* do Seg
// (já renderizados no preview E no export). Aba "Cortar" = livre; "Aproximar e Ampliar" =
// proporção travada na saída (a região preenche o quadro = zoom de verdade). ---
crop_tab:      int        // aba do modal: 0=Cortar 1=Aproximar e Ampliar
// Só existe UM recorte por segmento (sg.crop_*) e as duas abas editam ele: "Cortar"
// livre, "Aproximar e Ampliar" travado na proporção do projeto. Sem memória, entrar na
// aba de zoom conformava o recorte livre e ele voltava deformado para a aba "Cortar".
// Aqui cada aba lembra o SEU retângulo enquanto o modal está aberto; vale o da aba
// ATIVA quando o usuário confirma.
crop_memo:     [2][4]f32
crop_memo_ok:  [2]bool
crop_bk_seg:   int = -1   // segmento em edição no modal (-1 = modal fechado)
crop_bk:       [4]f32     // crop_x/y/w/h originais (restaurados no Cancelar)
crop_bk2:      [4]f32     // crop2_x/y/w/h originais (região do FIM)
crop_bk_anim:  bool       // zoom_anim original
crop_animate:  bool       // toggle "Animar zoom" dentro do modal (aba Aproximar e Ampliar)
crop_edit_end: bool       // no modo animado: false = editando o quadro Início, true = Fim
crop_play:     bool       // reproduzindo o clipe dentro do modal (mostra o resultado)
crop_play_t:   f32        // posição (s) da reprodução no modal, no tempo LOCAL do segmento



// ---------- prévia de origem (duplo-clique no bin: toca a mídia crua no player,
// sem colocá-la na timeline). Caminho próprio, isolado do playback da timeline. ----------
// (re)adquire o áudio da fonte na posição src_t, reusando os helpers de janela
src_acquire :: proc() {
	if src_preview < 0 do return
	c := &clips[src_preview]
	// ancora o relógio na posição PEDIDA (lição 3 da timeline): logo após Stop→Seek→Play o
	// GetMusicTimePlayed lê lixo (wrap p/ ~fim-do-arquivo por ~0.3s) — o smooth_clock rejeita
	// o glitch e captura quando o raw assentar perto da âncora
	aud_prev = clamp(src_t, 0, c.dur); smooth_bad = 0
	if !c.has_audio do return
	if audio_adopt_or_request(c, src_t) {
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(src_t - c.music_base, 0, msdur)
		rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target) // Stop zera os buffers antigos
		if st.playing do rl.PlayMusicStream(c.music)
		for _ in 0 ..< 8 do rl.UpdateMusicStream(c.music) // pré-enche c/ o áudio novo
	}
}

start_src_preview :: proc(i: int) {
	if i < 0 || i >= nclips || !media_ready(i) do return
	// silencia o áudio da timeline e o da prévia anterior (se trocando)
	if play_clip >= 0 && seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
	if src_preview >= 0 && src_preview != i && !clips[src_preview].closed && clips[src_preview].has_audio do rl.PauseMusicStream(clips[src_preview].music)
	for k in 0 ..< nclips do if clips[k].mix_on { rl.PauseMusicStream(clips[k].music); clips[k].mix_on = false } // silencia mix
	for k in 0 ..< nsegs do for s in 0 ..< 2 do if spv[k][s].on { rl.PauseMusicStream(spv[k][s].music); spv[k][s].on = false } // silencia spv
	play_clip = -1
	src_preview = i
	src_t = 0
	bin_sel = i; selected = -1
	st.playing = true
	src_acquire()
	clip_frame(&clips[i], 0) // mostra o 1º frame já neste frame
}

exit_src_preview :: proc() {
	if src_preview < 0 do return
	c := &clips[src_preview]
	if !c.closed && c.has_audio do rl.PauseMusicStream(c.music)
	src_preview = -1
	st.playing = false
}

// fonte + tempo (na fonte) do que está no player agora (prévia de origem OU timeline)
player_source :: proc() -> (pc: int, t: f32) {
	if src_preview >= 0 && src_preview < nclips && !clips[src_preview].closed do return src_preview, src_t
	v := view_seg()
	if v >= 0 do return segs[v].src, seg_local(v, st.playhead)
	return -1, 0
}

// salva o frame atual do player em `out` — COM as edições aplicadas. Antes isto
// redecodificava a FONTE no tempo t (`ffmpeg -ss`), então saía o vídeo ORIGINAL: sem
// recorte, transform, opacidade, cor/efeitos, texto, transição nem as outras trilhas.
// Agora compõe o MESMO `composite_video` do preview num RenderTexture do tamanho do
// projeto (padrão de render_text_png). Custo: a imagem vem da textura de PREVIEW
// (DEC_W×DEC_H), não da fonte em resolução cheia — o mesmo teto que o preview já tem.
take_screenshot :: proc(out: string) {
	// prévia de origem (duplo-clique no bin): não há edição aplicada, então vale mais a
	// resolução CHEIA da fonte — segue pelo ffmpeg.
	if src_preview >= 0 && src_preview < nclips {
		cmd := []string{
			"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
			"-ss", fmt.tprintf("%.3f", clamp(src_t, 0, clips[src_preview].dur)),
			"-i", clips[src_preview].path, "-frames:v", "1", "-update", "1", out,
		}
		// `e == nil` só diz que o ffmpeg FOI LANÇADO — fonte sem stream de vídeo, caminho
		// inválido ou arquivo em uso saem no código de saída, e sem olhá-lo o toast dizia
		// "salvo" (e contava o shot_n) sem nenhum arquivo no disco
		if p, e := os.process_start(os.Process_Desc{ command = cmd }); e == nil {
			state, _ := os.process_wait(p) // 1 frame: rápido
			if state.exited && state.exit_code == 0 {
				shot_n += 1
				import_screenshot_to_bin(out)
			} else {
				set_toast("Falha ao salvar screenshot")
			}
		} else {
			set_toast("Falha ao salvar screenshot")
		}
		return
	}
	if pc, _ := player_source(); pc < 0 { set_toast("Nada no player para capturar"); return }
	W, H := export_dims()
	rt := rl.LoadRenderTexture(i32(W), i32(H))
	if rt.texture.id == 0 { set_toast("Falha ao salvar screenshot"); return }
	rl.BeginTextureMode(rt)
	rl.ClearBackground(rl.BLACK) // fundo do canvas, igual ao preview
	any := composite_video(0, 0, f32(W), f32(H), false) // sel_box=false: sem a moldura de seleção
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(rt.texture)
	rl.ImageFlipVertical(&img)                     // RenderTexture vem espelhado no eixo Y
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)     // sem alfa: o JPG não a usa e o PNG fica menor
	ok := any && rl.ExportImage(img, strings.clone_to_cstring(out, context.temp_allocator))
	rl.UnloadImage(img)
	rl.UnloadRenderTexture(rt)
	if ok {
		shot_n += 1
		import_screenshot_to_bin(out)
	} else {
		set_toast(any ? "Falha ao salvar screenshot" : "Nada no player para capturar")
	}
}

// screenshot salvo no disco entra no bin como imagem (sem colocar na timeline)
import_screenshot_to_bin :: proc(out: string) {
	slot, _ := import_or_select(out, false)
	if slot >= 0 {
		set_toast(rl.TextFormat("Screenshot no bin: %s", cs(out)))
	} else {
		set_toast(rl.TextFormat("Screenshot salvo: %s", cs(out)))
	}
}

// estado da janela ao ENTRAR na tela cheia, p/ devolvê-lo na saída. O código antigo
// re-maximizava sempre, com a premissa (falsa) de que a janela é "SEMPRE maximizada": o botão
// de restaurar da barra de topo e o arrasto da barra deixam a janela em tamanho reduzido, e
// uma ida e volta à tela cheia jogava fora o tamanho e a posição escolhidos pelo usuário.
fs_was_max: bool = true // sem registro (não deveria acontecer), mantém o comportamento antigo
fs_prev_pos: rl.Vector2
fs_prev_w, fs_prev_h: i32

toggle_fullscreen_preview :: proc() {
	if !fullscreen_preview { // ENTRANDO: guarda o que a janela era, ANTES do toggle mexer nela
		fs_was_max = rl.IsWindowMaximized()
		if !fs_was_max {
			fs_prev_pos = rl.GetWindowPosition()
			fs_prev_w = i32(rl.GetScreenWidth()); fs_prev_h = i32(rl.GetScreenHeight())
		}
	}
	fullscreen_preview = !fullscreen_preview
	// tela cheia SEM borda que cobre o monitor INTEIRO (inclusive a barra de tarefas do
	// Windows). O ToggleFullscreen deixava a barra de tarefas aparecer no rodapé.
	rl.ToggleBorderlessWindowed()
	if fullscreen_preview {
		fs_ctl_alpha = 1; fs_ctl_hold = 3 // ao entrar, mostra os controles por uns segundos
	} else {
		// ao voltar pro modo janela, o ToggleBorderlessWindowed devolve a borda/barra de
		// título NATIVAS do Windows E restaura um tamanho errado (menor que a tela, sobra
		// desktop embaixo). A janela nasce SEM decoração, então: re-aplica "sem decoração",
		// limpa o estado inconsistente e devolve o que ela ERA antes da tela cheia.
		rl.SetWindowState({ .WINDOW_UNDECORATED })
		rl.RestoreWindow() // limpa estado maximizado inconsistente deixado pelo toggle
		if fs_was_max {
			rl.MaximizeWindow()
		} else if fs_prev_w > 0 && fs_prev_h > 0 { // devolve tamanho E posição escolhidos
			rl.SetWindowSize(fs_prev_w, fs_prev_h)
			rl.SetWindowPosition(i32(fs_prev_pos.x), i32(fs_prev_pos.y))
		} else {
			rl.MaximizeWindow()
		}
		rl.ShowCursor(); fs_vol_drag = false; player_seek_drag = false // garante o cursor de volta
	}
}

// multiplica a opacidade de uma cor por `a` (p/ o fade dos controles em tela cheia)
fa :: proc(c: rl.Color, a: f32) -> rl.Color {
	return { c.r, c.g, c.b, u8(clamp(f32(c.a) * a, 0, 255)) }
}

// desenha só o vídeo ocupando a janela toda (modo tela cheia), com controles
// no rodapé estilo NLE: somem sozinhos e reaparecem ao mexer o mouse ali perto
draw_fullscreen_video :: proc(sw, sh: f32) {
	rl.DrawRectangleRec({ 0, 0, sw, sh }, rl.BLACK)
	// canvas na janela toda: proporção do projeto — ou, na prévia de origem, a da fonte
	par := preview_ar()
	scaleC := min(sw/par, sh)
	fw := par*scaleC; fh := scaleC
	fx := (sw-fw)/2; fy := (sh-fh)/2
	if src_preview >= 0 { // prévia de origem: fonte na PRÓPRIA proporção, preenchendo o canvas
		c := &clips[src_preview]
		ensure_tex(c)
		if c.tex_ok do rl.DrawTexturePro(c.tex, dec_content_rect(c), { fx, fy, fw, fh }, {0,0}, 0, rl.WHITE)
	} else {
		rl.BeginScissorMode(i32(fx), i32(fy), i32(fw), i32(fh)) // transform não vaza do frame
		composite_video(fx, fy, fw, fh, false) // MESMO compositing/transforms do editor
		rl.EndScissorMode()
	}

	// ---- auto-hide dos controles ----
	dt := rl.GetFrameTime()
	m  := rl.GetMousePosition()
	bh: f32 = 96 // altura da barra de controles
	d  := rl.GetMouseDelta()
	moved := abs(d.x) + abs(d.y) > 0.5
	hot   := m.y >= sh - bh - 48 // mouse na barra (ou logo acima): mantém aparecendo
	active := moved || hot || player_seek_drag || fs_vol_drag || rl.IsMouseButtonDown(.LEFT)
	if active do fs_ctl_hold = 2 // "vive" por +2s a cada atividade
	else do fs_ctl_hold = max(0, fs_ctl_hold - dt)
	target: f32 = fs_ctl_hold > 0 ? 1 : 0
	fs_ctl_alpha += (target - fs_ctl_alpha) * min(1, dt * 12) // fade rápido

	a := fs_ctl_alpha
	if a <= 0.02 do return // totalmente escondido: nada de barra (o cursor do mouse NÃO some)
	interactive := a > 0.5 // escondido não recebe clique (o 1º só revela, estilo player)

	// gradiente de escurecimento no rodapé p/ leitura dos controles sobre o vídeo
	bar_y := sh - bh
	rl.DrawRectangleGradientV(0, i32(bar_y - 54), i32(sw), i32(bh + 54), fa({0,0,0,0}, a), fa({0,0,0,205}, a))

	// --- barra de progresso (posição atual / duração total, arrastável) ---
	total := src_preview >= 0 ? (src_preview < nclips ? clips[src_preview].dur : 0) : timeline_dur()
	pos   := src_preview >= 0 ? src_t : st.playhead
	pbar := rl.Rectangle{ 28, bar_y + 26, sw - 56, 6 }
	pbar_hit := rl.Rectangle{ pbar.x - 6, pbar.y - 9, pbar.width + 12, 24 }
	frac := total > 0 ? clamp(pos / total, 0, 1) : 0
	rl.DrawRectangleRounded(pbar, 1, 4, fa({ 70, 74, 86, 255 }, a))
	rl.DrawRectangleRounded({ pbar.x, pbar.y, frac * pbar.width, pbar.height }, 1, 4, fa(ACCENT, a))
	pkx := pbar.x + frac * pbar.width
	rl.DrawCircleV({ pkx, pbar.y + pbar.height/2 }, (player_seek_drag || hovered(pbar_hit)) ? 8 : 6, fa(rl.WHITE, a))
	if interactive && rl.IsMouseButtonPressed(.LEFT) && hovered(pbar_hit) { player_seek_drag = true; seek_was_playing = st.playing; st.playing = false; seek_drag_hush() }
	if rl.IsMouseButtonReleased(.LEFT) && player_seek_drag {
		player_seek_drag = false
		// retoma ANTES do seek: tanto src_acquire quanto seek_global só adquirem o áudio
		// na posição nova se st.playing já for true (senão voltaria mudo por um frame)
		if seek_was_playing { st.playing = true; seek_was_playing = false }
		when DBG_SEEK do dbg_seek_n = 200
		if src_preview >= 0 { src_acquire(); clip_frame(&clips[src_preview], src_t) } else do seek_global(st.playhead)
	}
	if player_seek_drag && total > 0 {
		np := clamp((m.x - pbar.x) / pbar.width, 0, 1) * total
		if src_preview >= 0 {
			src_t = np
			if !clips[src_preview].streaming do clip_show(&clips[src_preview], int(np * cfps_of(&clips[src_preview])))
			else {
				intrinsics.atomic_store(&scrub_req_c, src_preview)
				scrub_req_t = src_t
			}
		} else {
			st.playhead = np
			scrub_at_playhead()
		}
	}

	cy := bar_y + 62 // linha de botões abaixo da barra de progresso

	// play / pause (canto inferior esquerdo)
	pr := rl.Rectangle{ 26, cy - 18, 36, 36 }
	rl.DrawCircleV({ pr.x + 18, cy }, 18, fa(hovered(pr) ? ACCENT : ACCENT_D, a))
	if st.playing {
		rl.DrawRectangleRec({ pr.x + 12, cy - 8, 4, 16 }, fa(rl.WHITE, a))
		rl.DrawRectangleRec({ pr.x + 20, cy - 8, 4, 16 }, fa(rl.WHITE, a))
	} else {
		rl.DrawTriangle({ pr.x + 13, cy - 9 }, { pr.x + 13, cy + 9 }, { pr.x + 27, cy }, fa(rl.WHITE, a))
	}
	if interactive && clicked(pr) do toggle_play()

	// timecode: posição ATUAL / duração TOTAL
	txt(rl.TextFormat("%s / %s", timecode(pos), timecode(total)), pr.x + 52, cy - 9, 16, fa(TEXT, a))

	// --- sair da tela cheia (canto inferior direito): 4 cantoneiras p/ DENTRO ---
	fsr := rl.Rectangle{ sw - 44, cy - 12, 24, 24 }
	fc := fa(hovered(fsr) ? ACCENT : TEXT, a)
	L :: f32(8)
	rl.DrawLineEx({fsr.x + L, fsr.y}, {fsr.x + L, fsr.y + L}, 2, fc);                         rl.DrawLineEx({fsr.x, fsr.y + L}, {fsr.x + L, fsr.y + L}, 2, fc)
	rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y}, {fsr.x + fsr.width - L, fsr.y + L}, 2, fc);  rl.DrawLineEx({fsr.x + fsr.width, fsr.y + L}, {fsr.x + fsr.width - L, fsr.y + L}, 2, fc)
	rl.DrawLineEx({fsr.x + L, fsr.y + fsr.height}, {fsr.x + L, fsr.y + fsr.height - L}, 2, fc); rl.DrawLineEx({fsr.x, fsr.y + fsr.height - L}, {fsr.x + L, fsr.y + fsr.height - L}, 2, fc)
	rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y + fsr.height}, {fsr.x + fsr.width - L, fsr.y + fsr.height - L}, 2, fc); rl.DrawLineEx({fsr.x + fsr.width, fsr.y + fsr.height - L}, {fsr.x + fsr.width - L, fsr.y + fsr.height - L}, 2, fc)
	if interactive && clicked(fsr) { toggle_fullscreen_preview(); return }

	// --- volume: alto-falante (clique = mudo/desmuta) + slider horizontal ---
	vtr := rl.Rectangle{ fsr.x - 108, cy - 3, 90, 6 } // trilho do slider
	spr := rl.Rectangle{ vtr.x - 30, cy - 10, 22, 20 } // ícone do alto-falante à esquerda
	sc := player_vol < 0.01 ? fa({ 210, 100, 100, 255 }, a) : fa(hovered(spr) ? ACCENT : TEXT, a)
	{
		bx := spr.x + 3; bcy := spr.y + spr.height/2
		rl.DrawRectangleRec({bx, bcy - 3, 3.5, 6}, sc)
		rl.DrawTriangle({bx + 3.5, bcy - 6}, {bx + 3.5, bcy + 6}, {bx + 9, bcy}, sc)
		if player_vol < 0.01 {
			rl.DrawLineEx({bx + 11, bcy - 4}, {bx + 17, bcy + 4}, 1.8, sc)
			rl.DrawLineEx({bx + 17, bcy - 4}, {bx + 11, bcy + 4}, 1.8, sc)
		} else {
			rl.DrawRing({bx + 6, bcy}, 5.2, 6.4, -55, 55, 12, sc)
			rl.DrawRing({bx + 6, bcy}, 3.0, 3.9, -55, 55, 12, sc)
		}
	}
	if interactive && clicked(spr) do player_vol = player_vol < 0.01 ? 1 : 0
	vhit := rl.Rectangle{ vtr.x - 4, vtr.y - 9, vtr.width + 8, 24 }
	rl.DrawRectangleRounded(vtr, 1, 4, fa({ 70, 74, 86, 255 }, a))
	rl.DrawRectangleRounded({ vtr.x, vtr.y, player_vol * vtr.width, vtr.height }, 1, 4, fa(ACCENT, a))
	rl.DrawCircleV({ vtr.x + player_vol * vtr.width, vtr.y + vtr.height/2 }, (fs_vol_drag || hovered(vhit)) ? 7 : 5, fa(rl.WHITE, a))
	if interactive && rl.IsMouseButtonPressed(.LEFT) && hovered(vhit) do fs_vol_drag = true
	if rl.IsMouseButtonReleased(.LEFT) do fs_vol_drag = false
	if fs_vol_drag do player_vol = clamp((m.x - vtr.x) / vtr.width, 0, 1)

	// dica curta (some junto com os controles)
	txt("Esc: sair  ·  Espaço: play/pause", 26, bar_y + 4, 13, fa({ 210, 210, 215, 190 }, a))
}

// playback da prévia de origem (chamado no update quando src_preview >= 0)
update_src_preview :: proc(dt: f32) {
	c := &clips[src_preview]
	if c.closed || intrinsics.atomic_load(&c.failed) { src_preview = -1; st.playing = false; return }
	if !st.playing do return
	if c.has_audio && audio_clock_ok(c, src_t) {
		rl.SetMusicVolume(c.music, player_vol) // volume do player (monitor)
		rl.UpdateMusicStream(c.music)
		nt := smooth_clock(rl.GetMusicTimePlayed(c.music) + c.music_base, dt) // relógio suave (anti-judder)
		aud_prev = nt
		src_t = nt
		if !rl.IsMusicStreamPlaying(c.music) && src_t < c.dur - 0.25 do rl.ResumeMusicStream(c.music) // underrun
	} else {
		// fora da janela ativa (ou sem áudio): relógio de parede. audio_adopt_or_request
		// não pede chunk na cauda do completo (0.25s finais, ou áudio mais curto que o
		// vídeo) — pedir extraía a cauda, a adoção rebobinava ~1s e o fim virava loop.
		// Adotou uma janela NOVA? Tem de reposicionar o stream em src_t (src_acquire
		// seeka; tocar do início da janela deixava o PLL 1s atrás para sempre).
		if c.has_audio && audio_adopt_or_request(c, src_t) do src_acquire()
		else do src_t += dt
	}
	if src_t >= c.dur - 0.02 { // fim da fonte: para no fim
		src_t = c.dur
		st.playing = false
		if c.has_audio do rl.PauseMusicStream(c.music)
	}
	when DBG_SEEK do if dbg_seek_n > 0 {
		dbg_seek_n -= 1
		fmt.eprintfln("[seek/PREVIA-BIN] src_t=%.3f/%.0f raw=%.3f d_aud=%+.3f clock_ok=%v play=%v | CHUNK busy=%v done=%v ok=%v base=%.1f cobre=%v | parts=%d mbase=%.1f | VIDEO ATRASO=%+.3f",
			f64(src_t), f64(c.dur), f64(rl.GetMusicTimePlayed(c.music) + c.music_base),
			f64((rl.GetMusicTimePlayed(c.music) + c.music_base) - src_t),
			c.has_audio ? audio_clock_ok(c, src_t) : false,
			c.has_audio ? rl.IsMusicStreamPlaying(c.music) : false,
			c.chunk_busy, intrinsics.atomic_load(&c.chunk_done), intrinsics.atomic_load(&c.chunk_ok),
			f64(c.chunk_base), src_t >= c.chunk_base && src_t < c.chunk_base + CHUNK_SECS - 0.5,
			intrinsics.atomic_load(&c.parts_done), f64(c.music_base),
			f64(src_t - c.tex_t))
	}
	// DISPLAY: o passo travado no vsync agora mora DENTRO do clip_frame (ramo de cache),
	// compartilhado com o playback da timeline — um mecanismo só p/ os dois caminhos.
	clip_frame(c, src_t)
}

// silencia o áudio ativo no INSTANTE em que a barra de progresso é agarrada: setar só
// st.playing=false deixava o rl.Music tocando ~0.7s de buffer velho durante o arrasto
// (o update para de alimentá-lo e ele morre por starvation, não por pausa). Pausa
// EXPLÍCITA e deliberada de um gesto de seek — não é o "pause em clique global" da lição 1
// (aqui o playback já foi parado junto, então o update não interpreta como fim de clipe).
seek_drag_hush :: proc() {
	if src_preview >= 0 && src_preview < nclips {
		c := &clips[src_preview]
		if !c.closed && c.has_audio do rl.StopMusicStream(c.music)
	} else {
		hush_all_music()
		seek_rearm_si = -1
	}
}

// para o playback da timeline e silencia o stream-relógio. Sem o Pause, os
// ~0.7s de buffer já enfileirados continuam saindo depois que o vídeo acabou.
stop_timeline_play :: proc() {
	hush_all_music()
	seek_rearm_si = -1
	st.playing = false
}

toggle_play :: proc() {
	if src_preview >= 0 { // prévia de origem: espaço toca/pausa a fonte
		c := &clips[src_preview]
		if st.playing {
			st.playing = false
			if c.has_audio do rl.PauseMusicStream(c.music)
		} else {
			if src_t >= c.dur - 0.03 do src_t = 0
			st.playing = true
			src_acquire()
		}
		return
	}
	if nsegs == 0 { return }
	if st.playing {
		stop_timeline_play()
		return
	}
	if st.playhead >= timeline_dur() - 0.03 do seek_global(0)
	st.playing = true // update() adquire o áudio do segmento sob o playhead
}

// compõe as trilhas de vídeo sob o playhead (base->topo) dentro do frame {fx,fy,fw,fh},
// cada uma com seu transform (escala/posição/rotação/opacidade). Retorna se desenhou algo.
// sel_box=true desenha a caixa do segmento selecionado (só no editor, não na tela cheia).
// desenha o texto de um clipe de TEXTO dentro do canvas {fx,fy,fw,fh}, com o transform
// do segmento (tamanho×escala, posição, rotação, opacidade). Usado no preview E no PNG
// do export (mesma renderização = WYSIWYG). Sombra sutil p/ legibilidade sobre qualquer fundo.
// fonte escolhida do clipe de texto (índice válido; 0 se fora da faixa)
text_font_of :: proc(c: ^Clip) -> rl.Font {
	i := c.text_font
	if i < 0 || i >= len(text_fonts) do i = 0
	return len(text_fonts) > 0 ? text_fonts[i].font : ui_font
}

// quebra `s` em até 8 linhas que cabem em `max_w` (palavras; linha única se for um título curto).
text_wrap :: proc(fnt: rl.Font, s: string, fsz, spacing, max_w: f32) -> (lines: [8]string, n: int, dim: rl.Vector2) {
	if s == "" do return
	lh := fsz * 1.18
	push :: proc(lines: ^[8]string, n: ^int, dim: ^rl.Vector2, fnt: rl.Font, line: string, fsz, spacing, lh: f32) {
		if n^ >= len(lines) || line == "" do return
		lines[n^] = line
		w := rl.MeasureTextEx(fnt, cs(line), fsz, spacing).x
		if w > dim.x do dim.x = w
		n^ += 1
		dim.y = f32(n^) * lh
	}
	// sem espaço e cabe numa linha: título curto, caminho antigo
	if strings.index_byte(s, ' ') < 0 && strings.index_byte(s, '\n') < 0 {
		w := rl.MeasureTextEx(fnt, cs(s), fsz, spacing).x
		if w <= max_w || max_w < 8 {
			lines[0] = s; n = 1; dim = { w, lh }
			return
		}
	}
	start := 0
	cur := 0
	i := 0
	for i <= len(s) && n < 8 {
		at_end := i == len(s)
		brk := at_end || s[i] == ' ' || s[i] == '\n'
		if !brk { i += 1; continue }
		cand := strings.trim_space(s[start:i])
		if cand != "" {
			w := rl.MeasureTextEx(fnt, cs(cand), fsz, spacing).x
			if w > max_w && cur > start {
				push(&lines, &n, &dim, fnt, strings.trim_space(s[start:cur]), fsz, spacing, lh)
				start = cur
				for start < i && (s[start] == ' ' || s[start] == '\n') do start += 1
			}
			cur = i
		}
		if at_end || s[i] == '\n' {
			push(&lines, &n, &dim, fnt, strings.trim_space(s[start:i]), fsz, spacing, lh)
			start = i + 1
			cur = start
		}
		if at_end do break
		i += 1
	}
	if n == 0 {
		lines[0] = s; n = 1
		dim = rl.MeasureTextEx(fnt, cs(s), fsz, spacing)
		if dim.y < lh do dim.y = lh
	}
	return
}

// caixa / contorno em torno do bloco de texto (hit-test e sel_box).
text_style_pad :: proc(c: ^Clip, fsz: f32) -> (px, py: f32) {
	st := max(f32(0), c.cap_stroke) * fsz
	if c.cap_box > 0.01 {
		return fsz*0.28 + st, fsz*0.16 + st
	}
	if st > 0.4 do return st + 1, st + 1
	return max(f32(1), fsz*0.03), max(f32(1), fsz*0.03)
}

draw_text_stroke :: proc(fnt: rl.Font, t: cstring, pos: rl.Vector2, origin: rl.Vector2, rot, fsz, spacing, thick: f32, col: rl.Color) {
	if thick < 0.4 do return
	dirs := [8]rl.Vector2{ {1,0}, {-1,0}, {0,1}, {0,-1}, {0.72,0.72}, {-0.72,0.72}, {0.72,-0.72}, {-0.72,-0.72} }
	if abs(rot) > 0.5 {
		for d in dirs do rl.DrawTextPro(fnt, t, { pos.x + d.x*thick, pos.y + d.y*thick }, origin, rot, fsz, spacing, col)
	} else {
		for d in dirs do rl.DrawTextEx(fnt, t, { pos.x + d.x*thick, pos.y + d.y*thick }, fsz, spacing, col)
	}
}

draw_text_into :: proc(c: ^Clip, sg: Seg, fx, fy, fw, fh: f32, src_t: f32 = 0) {
	if !c.is_text do return
	body := clip_text_at(c, src_t)
	if body == "" do return
	if c.cap_upper do body = strings.to_upper(body, context.temp_allocator)
	fnt := text_font_of(c)
	scl := sg.scale <= 0 ? f32(1) : sg.scale
	fsz := max(f32(10), c.text_size * fh * scl)
	spacing := fsz * (c.cap_preset == .CapCut ? 0.04 : 0.06)
	max_w := fw * 0.86
	lines, n, dim := text_wrap(fnt, body, fsz, spacing, max_w)
	if n <= 0 do return
	cx := fx + fw/2 + sg.px*fw
	cy := fy + fh/2 + sg.py*fh
	op := sg.opacity <= 0 ? f32(1) : sg.opacity
	col := c.text_color; col.a = u8(clamp(op, 0, 1) * 255)
	sh := rl.Color{ 0, 0, 0, u8(clamp(op, 0, 1) * 150) }
	off := max(f32(1), fsz*0.03)
	lh := fsz * 1.18
	stroke := max(f32(0), c.cap_stroke) * fsz
	box_on := c.cap_box > 0.01
	bcol := c.cap_box_col
	bcol.a = u8(clamp(op * c.cap_box, 0, 1) * 255)
	scol := rl.Color{ 0, 0, 0, col.a }
	padx, pady := text_style_pad(c, fsz)
	if sdf_ok do rl.BeginShaderMode(sdf_shader)
	if n == 1 && abs(sg.rot) > 0.5 {
		t := cs(lines[0])
		origin := rl.Vector2{ dim.x/2, dim.y/2 }
		if box_on {
			rl.DrawRectanglePro({ cx, cy, dim.x + 2*padx, dim.y + 2*pady }, { dim.x/2 + padx, dim.y/2 + pady }, sg.rot, bcol)
		}
		draw_text_stroke(fnt, t, { cx, cy }, origin, sg.rot, fsz, spacing, stroke, scol)
		if !box_on && stroke < 0.4 {
			rl.DrawTextPro(fnt, t, { cx + off, cy + off }, origin, sg.rot, fsz, spacing, sh)
		}
		rl.DrawTextPro(fnt, t, { cx, cy }, origin, sg.rot, fsz, spacing, col)
	} else {
		y0 := cy - dim.y/2
		for k in 0 ..< n {
			t := cs(lines[k])
			lw := rl.MeasureTextEx(fnt, t, fsz, spacing).x
			px := cx - lw/2
			py := y0 + f32(k)*lh
			if box_on {
				round := c.cap_preset == .Marker ? f32(0.45) : f32(0.22)
				rl.DrawRectangleRounded({ px - padx, py - pady*0.45, lw + 2*padx, fsz + pady*1.15 }, round, 6, bcol)
			}
			draw_text_stroke(fnt, t, { px, py }, {}, 0, fsz, spacing, stroke, scol)
			if !box_on && stroke < 0.4 {
				rl.DrawTextEx(fnt, t, { px + off, py + off }, fsz, spacing, sh)
			}
			rl.DrawTextEx(fnt, t, { px, py }, fsz, spacing, col)
		}
	}
	if sdf_ok do rl.EndShaderMode()
}

// renderiza o texto do segmento num PNG RGBA (transparente) do tamanho do canvas de
// export, via RenderTexture (mesma fonte/shader do preview). Roda na MAIN (GL).
render_text_png :: proc(c: ^Clip, sg: Seg, path: string) -> bool {
	W, H := export_dims()
	rt := rl.LoadRenderTexture(i32(W), i32(H))
	if rt.texture.id == 0 do return false
	rl.BeginTextureMode(rt)
	rl.ClearBackground(rl.BLANK) // fundo transparente
	draw_text_into(c, sg, 0, 0, f32(W), f32(H))
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(rt.texture)
	rl.ImageFlipVertical(&img) // RenderTexture vem espelhado no eixo Y
	ok := rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))
	rl.UnloadImage(img)
	rl.UnloadRenderTexture(rt)
	return ok
}

// o filmstrip só substitui o último frame decodificado se estiver MAIS PERTO do
// cursor. `tex_t` perto (≤ SCRUB_SHARP_S) sempre vence — é nítido e já é o momento.
// Empate: fica o frame (nitidez). Thumb mais longe que o frame: fica o frame.
scrub_use_thumb :: proc(c: ^Clip, lt: f32) -> bool {
	if c.nthumbs <= 0 || c.thumb_dt <= 0 do return false
	err_tex := abs(lt - c.tex_t)
	if err_tex <= SCRUB_SHARP_S do return false
	ti := clamp(int(lt / c.thumb_dt), 0, c.nthumbs - 1)
	thumb_t := (f32(ti) + 0.5) * c.thumb_dt
	return abs(lt - thumb_t) < err_tex
}

// player e arrasto usam a MESMA regra: frame nítido se está perto; senão a miniatura
// mais próxima do cursor. Barrar o filmstrip no arrasto deixava o 720p CONGELADO o
// gesto inteiro num vídeo de horas (o worker não alcança). 256×144 é borrado, mas
// a cena CERTA — e o worker substitui pelo 720p quando chega.
scrub_player_uses_thumb :: proc(c: ^Clip, lt: f32) -> bool {
	return scrub_use_thumb(c, lt)
}

// desenha UM segmento de vídeo/texto no canvas com um multiplicador de opacidade
// (usado pelo blend da transição: clipe que sai × (1-p), clipe que entra × p).
// `vt` é o tempo de EXIBIÇÃO (view_t), não o playhead cru — ver view_t.
// wipe_feather>0 = dissolve orgânico (fumaça + opacidade). wipe_inv>0 = clipe que SAI.
draw_seg_composited :: proc(i: int, vt, opac_mul, fx, fy, fw, fh: f32, sel_box: bool, wipe_edge: f32 = 0, wipe_feather: f32 = 0, wipe_inv: f32 = 0, wipe_kind: f32 = 0, off_x: f32 = 0, off_y: f32 = 0, scl_mul: f32 = 1, rot_add: f32 = 0, sx_mul: f32 = 1, glitch: f32 = 0) {
	c := seg_src(i)
	sg := segs[i]
	// fade preto (rampa de opacidade) — só na região NORMAL do clipe (não no lead-in de dissolver)
	bfade := f32(1)
	if vt >= sg.start {
		p := vt - sg.start
		if sg.vfin  > 0.01 && p < sg.vfin              do bfade = min(bfade, clamp(p / sg.vfin, 0, 1))
		if sg.vfout > 0.01 && p > sg.dur - sg.vfout    do bfade = min(bfade, clamp((sg.dur - p) / sg.vfout, 0, 1))
	}
	op := (sg.opacity <= 0 ? f32(1) : sg.opacity) * clamp(opac_mul, 0, 1) * bfade
	if c.is_text { // clipe de texto: desenha a própria fonte (sem textura)
		if wipe_kind > 1.5 { // texto não tem máscara no shader: dissolve de opacidade
			op *= wipe_inv > 0.5 ? (1 - clamp(wipe_edge, 0, 1)) : clamp(wipe_edge, 0, 1)
		}
		sg2 := sg; sg2.opacity = op
		sg2.px += off_x; sg2.py += off_y
		if scl_mul > 0.01 do sg2.scale = (sg2.scale <= 0 ? f32(1) : sg2.scale) * scl_mul
		sg2.rot += rot_add
		src_t := seg_local(i, vt)
		draw_text_into(c, sg2, fx, fy, fw, fh, src_t)
		if sel_box && i == selected {
			scl := sg.scale <= 0 ? f32(1) : sg.scale
			fsz := max(f32(10), c.text_size*fh*scl); sp := fsz*0.06
			body := clip_text_at(c, src_t)
			if body == "" do body = c.text
			if c.cap_upper do body = strings.to_upper(body, context.temp_allocator)
			_, _, dim := text_wrap(text_font_of(c), body, fsz, sp, fw*0.86)
			padx, pady := text_style_pad(c, fsz)
			bxc := fx + fw/2 + sg.px*fw; byc := fy + fh/2 + sg.py*fh
			rl.DrawRectangleLinesEx({ bxc - dim.x/2 - padx - 4, byc - dim.y/2 - pady - 3, dim.x + 2*padx + 8, dim.y + 2*pady + 6 }, 1.5, ACCENT)
		}
		return
	}
	ensure_tex(c)
	// vista duplicada (mesma fonte em trilha mais baixa): desenha a textura própria
	// do seg; enquanto ela não tem frame, cai na textura da fonte (frame do outro seg)
	tex := c.tex
	tw_ := f32(cdw(c)); th_ := f32(cdh(c)) // dims da textura EM USO (src e UVs derivam daqui)
	if seg_is_dup(i) && seg_dup[i].ok && seg_dup[i].src == sg.src do tex = seg_dup[i].tex
	else if !c.tex_ok do return
	else if c.streaming && c.thumbs_ready && c.nthumbs > 0 {
		// seek/arrasto: se o frame nítido está longe e a miniatura está mais perto do
		// alvo, mostra o filmstrip (cena certa, borrada) até o worker chegar. Playback
		// contínuo não pisca thumb (catch-up).
		lt := seg_local(i, vt)
		dragging := st.drag == .Playhead || player_seek_drag
		waiting := dragging || !st.playing || intrinsics.atomic_load(&c.rsp_busy)
		past_eof := c.eof_at > 0 && lt >= c.eof_at - 0.05 // além do fim real: congela (comportamento antigo)
		if waiting && !past_eof && scrub_player_uses_thumb(c, lt) {
			tex = c.thumbs[clamp(int(lt / c.thumb_dt), 0, c.nthumbs - 1)]
			tw_ = f32(THUMB_W); th_ = f32(THUMB_H)
			if st.playing do dbg_thumb_frames += 1 // diagnóstico: miniatura mostrada DURANTE o playback (flash borrado)
		}
	}
	s := (sg.scale <= 0 ? f32(1) : sg.scale) * (scl_mul <= 0.01 ? f32(1) : scl_mul)
	ox := off_x; oy := off_y
	if glitch > 0.01 {
		ox += 0.014 * math.sin(vt * 83)
		oy += 0.010 * math.cos(vt * 67)
	}
	// RECORTE: fonte = sub-região; ajusta a REGIÃO recortada ao canvas preservando o aspecto dela.
	// seg_crop_at anima a região no tempo quando zoom_anim (Pan & Zoom); senão = recorte estático.
	crx, cry, crw, crh := seg_crop_at(i, vt)
	// QUADRO da fonte = conteúdo real (sem o pillarbox do DEC): crop e fit passam a operar no
	// aspecto verdadeiro, então 9:16 numa timeline 9:16 PREENCHE (antes o quadro 16:9 encolhia o vertical).
	cr := dec_content_rect(c)
	if tw_ != f32(cdw(c)) { // textura de miniatura: mesma geometria pillarbox, escala menor
		k := tw_ / f32(cdw(c))
		cr = { cr.x*k, cr.y*k, cr.width*k, cr.height*k }
	}
	src := rl.Rectangle{ cr.x + crx*cr.width, cr.y + cry*cr.height, crw*cr.width, crh*cr.height }
	cwpx := crw*cr.width; chpx := crh*cr.height
	tf := min(fw/cwpx, fh/chpx) // ajusta a região recortada ao canvas preservando aspecto
	sx := sx_mul <= 0.01 ? f32(1) : abs(sx_mul)
	dw := cwpx*tf*s*sx; dh := chpx*tf*s
	ccx := fx + fw/2 + (sg.px + ox)*fw; ccy := fy + fh/2 + (sg.py + oy)*fh
	tint := rl.Color{ 255, 255, 255, u8(clamp(op, 0, 1) * 255) }
	// COR: só o que o clipe tem (aba "Cor"); os clipes de EFEITO não são de cor.
	efb := sg.fx_bright; efc := sg.fx_contrast; efs := sg.fx_satur
	eft := sg.fx_temp; efv := sg.fx_vignette; efl := sg.fx_look
	// DISTORÇÃO efetiva: a do clipe; se ele não tiver e o efeito de FAIXA sob o playhead for
	// Distorção, aplica os parâmetros DELE (centro relativo ao quadro, tremor no tempo do efeito).
	b_str := bulge_at(sg, vt - sg.start)
	b_cx := clamp(0.5+sg.bulge_x, 0, 1); b_cy := clamp(0.5+sg.bulge_y, 0, 1)
	b_r := sg.bulge_r <= 0 ? BULGE_R_DEF : sg.bulge_r
	rgb_off := [2]f32{ 0, 0 } // separação RGB do efeito de faixa (0 = desligado)
	fxk := f32(0); fxa := f32(0); fxt := f32(0); fxa_ang := f32(0)
	// efeito de FAIXA que rege ESTA trilha (na trilha do seg ou numa acima — "afeta o que está embaixo")
	af := is_audio_track(sg.track) ? -1 : fx_for_track(sg.track)
	if af >= 0 {
		fs := fxsegs[af]
		if fs.kind == FX_DISTORT && !bulge_active(sg) {
			b_str = fx_bulge_strength(fs, vt - fs.start)
			b_cx = clamp(0.5+fs.cx, 0, 1); b_cy = clamp(0.5+fs.cy, 0, 1); b_r = fs.radius <= 0 ? BULGE_R_DEF : fs.radius
		} else if fs.kind == FX_RGB {
			rgb_off = fx_rgb_offset(fs)
		} else if fs.kind >= FX_PIXEL {
			fxk = f32(fs.kind); fxa = fs.amount; fxt = vt; fxa_ang = fs.angle
			if fs.kind == FX_SPOT {
				b_cx = clamp(0.5+fs.cx, 0, 1); b_cy = clamp(0.5+fs.cy, 0, 1)
				b_r = fs.radius <= 0 ? BULGE_R_DEF : fs.radius
			}
			if fs.kind == FX_SHAKE {
				hz := fs.speed <= 0 ? f32(8) : fs.speed
				fxt = vt * hz / 8 // o shader usa constantes 23/17; speed escala o tempo
			}
			if fs.kind == FX_WAVE {
				hz := fs.speed <= 0 ? f32(2) : fs.speed
				fxt = vt * hz
			}
		}
	}
	if glitch > 0.01 {
		rgb_off.x += glitch * 0.022
		rgb_off.y -= glitch * 0.016
	}
	use_fx := bulge_ok && (fx_any(sg) || af >= 0 || wipe_feather > 0.01 || wipe_kind > 1.5 || glitch > 0.01)
	if use_fx {
		br := b_r
		uv0 := [2]f32{ src.x/tw_, src.y/th_ } // src no espaço da textura EM USO (c.tex ou miniatura)
		uv1 := [2]f32{ (src.x+src.width)/tw_, (src.y+src.height)/th_ }
		ctr := [2]f32{ b_cx, b_cy }
		asp := dh > 0 ? dw/dh : 1
		st_ := b_str
		rl.SetShaderValue(bulge_shader, bulge_loc_uv0, &uv0, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_uv1, &uv1, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_center, &ctr, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_strength, &st_, .FLOAT)
		rl.SetShaderValue(bulge_shader, bulge_loc_radius, &br, .FLOAT)
		rl.SetShaderValue(bulge_shader, bulge_loc_aspect, &asp, .FLOAT)
		// uniforms de COR (neutro quando 0): contraste/saturação efetivos = 1+valor
		cbr := efb; cco := 1 + efc; csa := 1 + efs
		clk := efl; cvg := efv; ctp := eft
		rl.SetShaderValue(bulge_shader, fx_loc_bright, &cbr, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_contrast, &cco, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_satur, &csa, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_look, &clk, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_vignette, &cvg, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_temp, &ctp, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_rgb, &rgb_off, .VEC2)
		we := wipe_edge; wf := wipe_feather; wi := wipe_inv; wk := wipe_kind
		rl.SetShaderValue(bulge_shader, fx_loc_wipe_edge, &we, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_wipe_feather, &wf, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_wipe_inv, &wi, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_wipe_kind, &wk, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_kind, &fxk, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_amt, &fxa, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_time, &fxt, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_ang, &fxa_ang, .FLOAT)
		rl.BeginShaderMode(bulge_shader)
	}
	rl.DrawTexturePro(tex, src, { ccx, ccy, dw, dh }, { dw/2, dh/2 }, sg.rot + rot_add, tint)
	if use_fx do rl.EndShaderMode()
	if sel_box && i == selected {
		rad := sg.rot * math.PI/180; cs_ := math.cos(rad); sn := math.sin(rad)
		hw := dw/2; hh := dh/2
		cor :: proc(cx, cy, ox, oy, cs_, sn: f32) -> rl.Vector2 { return { cx + ox*cs_ - oy*sn, cy + ox*sn + oy*cs_ } }
		p0 := cor(ccx, ccy, -hw, -hh, cs_, sn); p1 := cor(ccx, ccy, hw, -hh, cs_, sn)
		p2 := cor(ccx, ccy, hw, hh, cs_, sn); p3 := cor(ccx, ccy, -hw, hh, cs_, sn)
		rl.DrawLineEx(p0, p1, 1.5, ACCENT); rl.DrawLineEx(p1, p2, 1.5, ACCENT)
		rl.DrawLineEx(p2, p3, 1.5, ACCENT); rl.DrawLineEx(p3, p0, 1.5, ACCENT)
	}
}

// wipe de tinta: p=0 nada de B; p=1 B inteiro. feather = borda da mancha.
ghost_wipe_edge :: proc(p: f32) -> (edge, feather: f32) {
	return clamp(p, 0, 1), 0.10
}

// segmento B cuja transição CENTRADA no corte cobre `time` na trilha t. A janela é
// [B.start - D/2, B.start + D/2] (metade em cada clipe). -1 se nenhum.
trans_overlap :: proc(t: int, time: f32) -> int {
	// o corte MAIS PRÓXIMO, não o primeiro do array: com duas janelas ainda se tocando (o
	// trans_max já as separa, mas a ordem do array não é a da timeline) devolver a errada
	// misturava os clipes do corte vizinho.
	best := -1; bd := f32(1e30)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || segs[i].track != t do continue
		d := seg_trans(i)
		if d > 0 {
			half := d/2
			if time >= segs[i].start - half && time < segs[i].start + half {
				if dd := abs(time - segs[i].start); dd < bd { bd = dd; best = i }
			}
		}
	}
	return best
}

composite_video :: proc(fx, fy, fw, fh: f32, sel_box: bool) -> bool {
	any := false
	vt := view_t() // no fim da timeline, o último frame em vez de preto
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta (olho): não compõe no preview
		tb := trans_overlap(t, vt) // transição centrada cobrindo o playhead?
		if tb >= 0 {
			a := trans_prev(tb)
			half := seg_trans(tb)/2; cut := segs[tb].start
			p := clamp((vt - (cut - half)) / (2*half), 0, 1) // 0 no início do overlap, 1 no fim
			mode := segs[tb].trans_mode
			if seg_ghost(tb) {
				// tinta: A some nas manchas, B aparece nas mesmas (máscara luma).
				edge, feather := ghost_wipe_edge(p)
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, edge, feather, 1) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, edge, feather, 0)
			} else if trans_is_mask(mode) {
				wk := f32(mode)
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, p, 0, 1, wk) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, p, 0, 0, wk)
			} else if trans_is_slide(mode) {
				dx, dy := trans_slide_dir(mode)
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, dx*p, dy*p) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, -dx*(1-p), -dy*(1-p))
			} else if mode == TRANS_ZOOM {
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 0.22 + 0.78*p)
			} else if mode == TRANS_ZOOM_OUT {
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1 + 0.85*p) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1.85 - 0.85*p)
			} else if mode == TRANS_SPIN {
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, 360*p) }
				any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, -360*(1-p))
			} else if mode == TRANS_FLIP {
				if p < 0.5 {
					sx := math.cos(p * math.PI) // 1 → 0
					if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, 0, max(sx, 0.02)) }
				} else {
					sx := math.cos((1-p) * math.PI) // 0 → 1
					any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, 0, max(sx, 0.02))
				}
			} else if mode == TRANS_GLITCH {
				g := 0.35 + 0.65*math.sin(p*math.PI) // pico no meio do corte
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1-p, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, 0, 1, g) }
				any = true; draw_seg_composited(tb, vt, p, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, 0, 0, 1, 0, 1, g)
			} else if mode == TRANS_SHAKE {
				amp := math.sin(p * math.PI) * 0.045
				ox := amp * math.sin(vt * 62)
				oy := amp * math.cos(vt * 49)
				if p < 0.5 {
					if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, ox, oy) }
				} else {
					any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box, 0, 0, 0, 0, ox, oy)
				}
			} else if mode == TRANS_FLASH {
				if p < 0.5 {
					if a >= 0 { any = true; draw_seg_composited(a, vt, 1, fx, fy, fw, fh, sel_box) }
					wh := u8(clamp(p*2, 0, 1) * 255)
					rl.DrawRectangleRec({ fx, fy, fw, fh }, rl.Color{ 255, 255, 255, wh })
				} else {
					any = true; draw_seg_composited(tb, vt, 1, fx, fy, fw, fh, sel_box)
					wh := u8(clamp((1-p)*2, 0, 1) * 255)
					rl.DrawRectangleRec({ fx, fy, fw, fh }, rl.Color{ 255, 255, 255, wh })
				}
			} else {
				if a >= 0 { any = true; draw_seg_composited(a, vt, 1-p, fx, fy, fw, fh, sel_box) } // SAI (cauda)
				any = true; draw_seg_composited(tb, vt, p, fx, fy, fw, fh, sel_box)                // ENTRA (cabeça)
			}
		} else {
			cur := seg_on_track_at(t, vt)
			if cur >= 0 {
				// overlay persistente: manchas já abertas (~meio da rampa)
				if segs[cur].trans_mode == 1 && segs[cur].trans <= 0.01 {
					any = true; draw_seg_composited(cur, vt, 1, fx, fy, fw, fh, sel_box, 0.50, 0.10)
				} else {
					any = true; draw_seg_composited(cur, vt, 1, fx, fy, fw, fh, sel_box)
				}
			}
		}
	}
	return any
}

// editor de RECORTE (crop): mostra o quadro COMPLETO do clipe selecionado ajustado ao canvas,
// escurece fora da região, e desenha 8 alças arrastáveis (cantos/bordas) + moldura de terços.
// Edita sg.crop_* diretamente (frações da fonte). Chamado no preview quando crop_mode.
draw_crop_editor :: proc(fx, fy, fw, fh: f32) {
	if selected < 0 || selected >= nsegs do return
	sg := &segs[selected]
	c := seg_src(selected)
	ensure_tex(c)
	cr := dec_content_rect(c)
	tff := min(fw/cr.width, fh/cr.height) // quadro de CONTEÚDO (aspecto da fonte) ajustado ao canvas
	fdw := cr.width*tff; fdh := cr.height*tff
	frx := fx + (fw-fdw)/2; fry := fy + (fh-fdh)/2
	if c.tex_ok do rl.DrawTexturePro(c.tex, cr, {frx,fry,fdw,fdh}, {0,0}, 0, rl.WHITE)
	crx, cry, crw, crh := seg_crop(selected)
	CR := rl.Rectangle{ frx+crx*fdw, fry+cry*fdh, crw*fdw, crh*fdh }
	// escurece fora do recorte (4 faixas em volta da região mantida)
	dim := rl.Color{ 0,0,0,150 }
	rl.DrawRectangleRec({frx, fry, fdw, CR.y-fry}, dim)
	rl.DrawRectangleRec({frx, CR.y+CR.height, fdw, (fry+fdh)-(CR.y+CR.height)}, dim)
	rl.DrawRectangleRec({frx, CR.y, CR.x-frx, CR.height}, dim)
	rl.DrawRectangleRec({CR.x+CR.width, CR.y, (frx+fdw)-(CR.x+CR.width), CR.height}, dim)
	rl.DrawRectangleLinesEx(CR, 1.5, rl.WHITE)
	for k in 1 ..< 3 { // guias de terços
		gx := CR.x + CR.width*f32(k)/3; gy := CR.y + CR.height*f32(k)/3
		rl.DrawLineEx({gx, CR.y},{gx, CR.y+CR.height}, 1, rl.Color{255,255,255,80})
		rl.DrawLineEx({CR.x, gy},{CR.x+CR.width, gy}, 1, rl.Color{255,255,255,80})
	}
	Hd := [8]rl.Vector2{
		{CR.x,CR.y},{CR.x+CR.width,CR.y},{CR.x+CR.width,CR.y+CR.height},{CR.x,CR.y+CR.height}, // cantos
		{CR.x+CR.width/2,CR.y},{CR.x+CR.width,CR.y+CR.height/2},{CR.x+CR.width/2,CR.y+CR.height},{CR.x,CR.y+CR.height/2}, // bordas
	}
	m := rl.GetMousePosition()
	for p, k in Hd {
		hov := crop_drag==k || (crop_drag<0 && abs(m.x-p.x)<9 && abs(m.y-p.y)<9)
		rl.DrawRectangleRec({p.x-5,p.y-5,10,10}, hov ? ACCENT : rl.WHITE)
		rl.DrawRectangleLinesEx({p.x-5,p.y-5,10,10}, 1, rl.Color{30,30,30,220})
	}
	// input: pegar alça / região; arrastar edita as frações
	if rl.IsMouseButtonPressed(.LEFT) && crop_drag<0 {
		hit := -1
		for p, k in Hd do if abs(m.x-p.x)<10 && abs(m.y-p.y)<10 { hit=k; break }
		if hit<0 && rl.CheckCollisionPointRec(m, CR) { hit=8; crop_grab = { (m.x-frx)/fdw - crx, (m.y-fry)/fdh - cry } }
		crop_drag = hit
	}
	if crop_drag>=0 && rl.IsMouseButtonDown(.LEFT) {
		mfx := clamp((m.x-frx)/fdw, 0, 1); mfy := clamp((m.y-fry)/fdh, 0, 1)
		x0:=crx; y0:=cry; x1:=crx+crw; y1:=cry+crh
		MIN :: f32(0.06)
		switch crop_drag {
		case 0: x0=min(mfx,x1-MIN); y0=min(mfy,y1-MIN)
		case 1: x1=max(mfx,x0+MIN); y0=min(mfy,y1-MIN)
		case 2: x1=max(mfx,x0+MIN); y1=max(mfy,y0+MIN)
		case 3: x0=min(mfx,x1-MIN); y1=max(mfy,y0+MIN)
		case 4: y0=min(mfy,y1-MIN)
		case 5: x1=max(mfx,x0+MIN)
		case 6: y1=max(mfy,y0+MIN)
		case 7: x0=min(mfx,x1-MIN)
		case 8: // mover mantendo o tamanho
			nx := clamp((m.x-frx)/fdw - crop_grab.x, 0, 1-crw); ny := clamp((m.y-fry)/fdh - crop_grab.y, 0, 1-crh)
			x0=nx; y0=ny; x1=nx+crw; y1=ny+crh
		}
		sg.crop_x=x0; sg.crop_y=y0; sg.crop_w=x1-x0; sg.crop_h=y1-y0
	}
	if rl.IsMouseButtonReleased(.LEFT) do crop_drag = -1
	rl.SetMouseCursor(.POINTING_HAND)
}

// ---------- modal "Cortar e Ampliar" ----------
// proporção da região (frações) que faz a área recortada preencher o quadro de saída sem tarjas:
// (w/h)*aspecto_fonte == proj_ar  =>  h = w * aspecto_fonte/proj_ar. Fonte e saída no mesmo aspecto
// => kh=1 (região cheia já preenche). Usa a fonte do seg selecionado (o modal opera sobre ele).
crop_lock_kh :: proc() -> f32 {
	car := selected >= 0 && selected < nsegs ? clip_ar(seg_src(selected)) : f32(DEC_W)/f32(DEC_H)
	return car / proj_ar
}

// conforma UMA região (por ponteiros p/ os 4 campos) à proporção travada, centrando na
// região existente (usado ao entrar na aba "Aproximar e Ampliar" e no Redefinir).
crop_conform_lock_q :: proc(qx, qy, qw, qh: ^f32) {
	kh := crop_lock_kh()
	w := qw^ <= 0 ? f32(1) : qw^
	cxr := (qw^ <= 0 ? f32(0) : qx^) + w/2
	cyr := (qh^ <= 0 ? f32(0) : qy^) + (qh^ <= 0 ? f32(1) : qh^)/2
	h := w*kh
	if h > 1 { h = 1; w = h/kh }
	qw^ = w; qh^ = h
	qx^ = clamp(cxr - w/2, 0, 1-w); qy^ = clamp(cyr - h/2, 0, 1-h)
}

crop_memo_save :: proc(tab: int, sg: ^Seg) {
	crop_memo[tab] = { sg.crop_x, sg.crop_y, sg.crop_w, sg.crop_h }
	crop_memo_ok[tab] = true
}
crop_memo_load :: proc(tab: int, sg: ^Seg) -> bool {
	if !crop_memo_ok[tab] do return false
	m := crop_memo[tab]
	sg.crop_x = m[0]; sg.crop_y = m[1]; sg.crop_w = m[2]; sg.crop_h = m[3]
	return true
}

// abre o modal p/ o segmento selecionado (só vídeo/imagem). Chamado pelo botão da toolbar.
open_crop_modal :: proc() {
	if selected < 0 || selected >= nsegs || !seg_ready(selected) do return
	c := seg_src(selected)
	if c.is_audio || c.is_text || segs[selected].aonly do return
	// os dois editores de recorte (o inline do preview e o do modal) compartilham crop_drag
	// e crop_grab, mas em geometrias diferentes. Rodando juntos, um press dentro do modal era
	// pego primeiro pelo do preview e depois aplicado com a escala do modal — a região saltava
	// para um canto e o OK gravava o recorte errado. O modal manda: desliga o modo inline.
	set_crop_mode(false)
	sg := &segs[selected]
	if !seg_cropped(selected) && !sg.zoom_anim { sg.crop_x = 0; sg.crop_y = 0; sg.crop_w = 1; sg.crop_h = 1 }
	crop_bk  = { sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h }   // backup p/ Cancelar
	crop_bk2 = { sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h }
	crop_bk_anim = sg.zoom_anim
	crop_bk_seg = selected
	// abre na aba "Cortar" (recorte livre) — é o que o botão promete. Exceção: o clipe
	// que JÁ tem animação de zoom abre na aba dela, senão o OK (zoom_anim = animate &&
	// crop_tab == 1) desligaria a animação existente sem o usuário pedir.
	crop_tab = sg.zoom_anim ? 1 : 0
	crop_animate = sg.zoom_anim
	crop_edit_end = false
	crop_memo_ok = { false, false } // memória por aba começa vazia a cada abertura
	crop_play = false; crop_play_t = 0 // começa pausado no início do clipe
	// a trava de proporção é da aba de zoom; na aba "Cortar" o recorte é livre. Entrar
	// na aba de zoom conforma na hora (ver o clique das abas).
	if crop_tab == 1 do crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h)
	if sg.crop2_w <= 0 { sg.crop2_x=sg.crop_x; sg.crop2_y=sg.crop_y; sg.crop2_w=sg.crop_w; sg.crop2_h=sg.crop_h } // fim = início
	crop_conform_lock_q(&sg.crop2_x, &sg.crop2_y, &sg.crop2_w, &sg.crop2_h)
	crop_drag = -1
	modal = .Crop
	// leva o playhead pra dentro do clipe p/ a textura mostrar o frame certo
	if st.playhead < sg.start || st.playhead >= sg.start + sg.dur do seek_global(sg.start + sg.dur*0.5)
}
crop_modal_cancel :: proc() { // descarta: restaura recorte + animação originais
	if crop_bk_seg >= 0 && crop_bk_seg < nsegs {
		sg := &segs[crop_bk_seg]
		sg.crop_x =crop_bk[0];  sg.crop_y =crop_bk[1];  sg.crop_w =crop_bk[2];  sg.crop_h =crop_bk[3]
		sg.crop2_x=crop_bk2[0]; sg.crop2_y=crop_bk2[1]; sg.crop2_w=crop_bk2[2]; sg.crop2_h=crop_bk2[3]
		sg.zoom_anim = crop_bk_anim
	}
	modal = .None; crop_bk_seg = -1; crop_drag = -1; crop_play = false
	show_playhead_frame() // restaura o frame do preview no playhead (o play do modal mexeu na textura)
}
crop_modal_ok :: proc() { // aplica
	if crop_bk_seg >= 0 && crop_bk_seg < nsegs {
		sg := &segs[crop_bk_seg]
		sg.zoom_anim = crop_animate && crop_tab == 1 // animação só faz sentido na aba de zoom
		// estático + região ~cheia = "sem recorte" (zero-value, evita marcar como recortado à toa)
		if !sg.zoom_anim && sg.crop_w > 0.999 && sg.crop_h > 0.999 { sg.crop_x=0; sg.crop_y=0; sg.crop_w=0; sg.crop_h=0 }
	}
	modal = .None; crop_bk_seg = -1; crop_drag = -1; crop_play = false
	show_playhead_frame() // restaura o frame do preview no playhead (o play do modal mexeu na textura)
}

// desenha o CONTORNO de uma região (fantasma do quadro inativo no modo animado)
crop_rect_ghost :: proc(qx, qy, qw, qh, frx, fry, fdw, fdh: f32, col: rl.Color) {
	nx, ny, nw, nh := crop_norm(qx, qy, qw, qh)
	R := rl.Rectangle{ frx+nx*fdw, fry+ny*fdh, nw*fdw, nh*fdh }
	rl.DrawRectangleLinesEx(R, 1.4, col)
}

// desenha e edita UMA região (ponteiros p/ os 4 campos) sobre o frame. lock=true trava a
// proporção. col = cor do contorno/alças (branco no crop; verde=início, vermelho=fim).
crop_rect_editor :: proc(qx, qy, qw, qh: ^f32, frx, fry, fdw, fdh: f32, lock: bool, col: rl.Color) {
	crx := qw^ <= 0 ? f32(0) : clamp(qx^, 0, 1)
	cry := qh^ <= 0 ? f32(0) : clamp(qy^, 0, 1)
	crw := qw^ <= 0 ? f32(1) : qw^
	crh := qh^ <= 0 ? f32(1) : qh^
	CR := rl.Rectangle{ frx+crx*fdw, fry+cry*fdh, crw*fdw, crh*fdh }
	dim := rl.Color{ 0,0,0,150 }
	rl.DrawRectangleRec({frx, fry, fdw, CR.y-fry}, dim)
	rl.DrawRectangleRec({frx, CR.y+CR.height, fdw, (fry+fdh)-(CR.y+CR.height)}, dim)
	rl.DrawRectangleRec({frx, CR.y, CR.x-frx, CR.height}, dim)
	rl.DrawRectangleRec({CR.x+CR.width, CR.y, (frx+fdw)-(CR.x+CR.width), CR.height}, dim)
	rl.DrawRectangleLinesEx(CR, 1.5, col)
	for k in 1 ..< 3 { // guias de terços
		gx := CR.x + CR.width*f32(k)/3; gy := CR.y + CR.height*f32(k)/3
		rl.DrawLineEx({gx, CR.y},{gx, CR.y+CR.height}, 1, rl.Color{255,255,255,80})
		rl.DrawLineEx({CR.x, gy},{CR.x+CR.width, gy}, 1, rl.Color{255,255,255,80})
	}
	Hd := [8]rl.Vector2{
		{CR.x,CR.y},{CR.x+CR.width,CR.y},{CR.x+CR.width,CR.y+CR.height},{CR.x,CR.y+CR.height}, // cantos
		{CR.x+CR.width/2,CR.y},{CR.x+CR.width,CR.y+CR.height/2},{CR.x+CR.width/2,CR.y+CR.height},{CR.x,CR.y+CR.height/2}, // bordas
	}
	nH := lock ? 4 : 8 // travado: só os 4 cantos (bordas quebrariam a proporção)
	m := rl.GetMousePosition()
	for k in 0 ..< nH {
		p := Hd[k]
		hov := crop_drag==k || (crop_drag<0 && abs(m.x-p.x)<9 && abs(m.y-p.y)<9)
		rl.DrawRectangleRec({p.x-5,p.y-5,10,10}, hov ? ACCENT : col)
		rl.DrawRectangleLinesEx({p.x-5,p.y-5,10,10}, 1, rl.Color{30,30,30,220})
	}
	if rl.IsMouseButtonPressed(.LEFT) && crop_drag<0 {
		hit := -1
		for k in 0 ..< nH do if abs(m.x-Hd[k].x)<10 && abs(m.y-Hd[k].y)<10 { hit=k; break }
		if hit<0 && rl.CheckCollisionPointRec(m, CR) { hit=8; crop_grab = { (m.x-frx)/fdw - crx, (m.y-fry)/fdh - cry } }
		crop_drag = hit
	}
	if crop_drag>=0 && rl.IsMouseButtonDown(.LEFT) {
		mfx := clamp((m.x-frx)/fdw, 0, 1); mfy := clamp((m.y-fry)/fdh, 0, 1)
		x0:=crx; y0:=cry; x1:=crx+crw; y1:=cry+crh
		MIN :: f32(0.06)
		if crop_drag == 8 { // mover mantendo o tamanho
			nx := clamp((m.x-frx)/fdw - crop_grab.x, 0, 1-crw); ny := clamp((m.y-fry)/fdh - crop_grab.y, 0, 1-crh)
			x0=nx; y0=ny; x1=nx+crw; y1=ny+crh
		} else if lock { // canto k: âncora = canto oposto (fixo); altura = largura*kh
			kh := crop_lock_kh()
			ax, ay: f32
			switch crop_drag {
			case 0: ax=x1; ay=y1
			case 1: ax=x0; ay=y1
			case 2: ax=x0; ay=y0
			case 3: ax=x1; ay=y0
			}
			w := max(abs(mfx-ax), MIN); h := w*kh
			left  := crop_drag==0 || crop_drag==3
			top   := crop_drag==0 || crop_drag==1
			if left  && ax-w < 0 { w = ax;   h = w*kh } // não passar da borda esquerda
			if !left && ax+w > 1 { w = 1-ax; h = w*kh } // ...direita
			if top   && ay-h < 0 { h = ay;   w = h/kh } // ...topo
			if !top  && ay+h > 1 { h = 1-ay; w = h/kh } // ...base
			w = max(w, MIN); h = max(h, MIN)
			x0 = left ? ax-w : ax; x1 = left ? ax : ax+w
			y0 = top  ? ay-h : ay; y1 = top  ? ay : ay+h
		} else { // recorte livre
			switch crop_drag {
			case 0: x0=min(mfx,x1-MIN); y0=min(mfy,y1-MIN)
			case 1: x1=max(mfx,x0+MIN); y0=min(mfy,y1-MIN)
			case 2: x1=max(mfx,x0+MIN); y1=max(mfy,y0+MIN)
			case 3: x0=min(mfx,x1-MIN); y1=max(mfy,y0+MIN)
			case 4: y0=min(mfy,y1-MIN)
			case 5: x1=max(mfx,x0+MIN)
			case 6: y1=max(mfy,y0+MIN)
			case 7: x0=min(mfx,x1-MIN)
			}
		}
		qx^=clamp(x0,0,1); qy^=clamp(y0,0,1)
		qw^=clamp(x1-x0,MIN,1); qh^=clamp(y1-y0,MIN,1)
	}
	if crop_drag>=0 && rl.IsMouseButtonReleased(.LEFT) do crop_drag = -1
}

CROP_START_COL :: rl.Color{ 90, 200, 120, 255 } // quadro Início (verde)
CROP_END_COL   :: rl.Color{ 235, 95, 82, 255 }   // quadro Fim (vermelho)

// modal em si (chamado por draw_modal). Frame + retângulo(s) + abas + animação + rodapé.
draw_crop_modal :: proc(sw, sh: f32) {
	if crop_bk_seg < 0 || crop_bk_seg >= nsegs || !seg_ready(crop_bk_seg) ||
	   seg_audio_like(crop_bk_seg) || seg_src(crop_bk_seg).is_text {
		modal = .None; crop_bk_seg = -1; crop_drag = -1; return
	}
	selected = crop_bk_seg // mantém o resto da UI apontando p/ o mesmo segmento
	sg := &segs[crop_bk_seg]
	c := seg_src(crop_bk_seg)

	rl.DrawRectangleRec({0,0,sw,sh}, rl.Color{ 0,0,0,180 })
	cw: f32 = 640; chh: f32 = 552
	cx := sw/2 - cw/2; cy := sh/2 - chh/2
	card := rl.Rectangle{ cx, cy, cw, chh }
	rl.DrawRectangleRounded(card, 0.03, 8, rl.Color{ 30, 33, 40, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.03, 8, 1, LINE)

	txt("Cortar e Ampliar", cx + 22, cy + 16, 18, TEXT)
	xr := rl.Rectangle{ cx + cw - 38, cy + 16, 24, 24 }
	if clicked(xr) { crop_modal_cancel(); return }
	rl.DrawLineEx({xr.x+6,xr.y+6},{xr.x+16,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+16,xr.y+6},{xr.x+6,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)

	// abas
	tabs := []cstring{ "Cortar", "Aproximar e Ampliar" }
	tws  := []f32{ 90, 180 }
	tx := cx + 22; ty := cy + 46
	for tab, i in tabs {
		tr := rl.Rectangle{ tx, ty, tws[i], 26 }
		if clicked(tr) && i != crop_tab {
			crop_memo_save(crop_tab, sg)          // guarda o retângulo da aba que sai
			if !crop_memo_load(i, sg) && i == 1 { // 1ª visita ao zoom: conforma o recorte atual
				crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h)
			}
			crop_tab = i
			crop_drag = -1
		}
		txt_c(tab, tr.x + tws[i]/2, tr.y + 6, 13, i == crop_tab ? TEXT : MUTED)
		if i == crop_tab do rl.DrawRectangleRec({ tr.x + 8, tr.y + 24, tws[i] - 16, 2 }, ACCENT)
		tx += tws[i] + 6
	}
	rl.DrawLine(i32(cx+22), i32(ty+28), i32(cx+cw-22), i32(ty+28), LINE)

	// linha de controles da animação (só na aba de zoom)
	ctrl_y := ty + 40
	if crop_tab == 1 {
		chk := rl.Rectangle{ cx + 22, ctrl_y, 18, 18 }
		if clicked(chk) do crop_animate = !crop_animate
		rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, crop_animate ? ACCENT : MUTED)
		if crop_animate do rl.DrawRectangleRec({ chk.x+4, chk.y+4, 10, 10 }, ACCENT)
		txt("Animar zoom (Início → Fim)", chk.x + 26, ctrl_y + 2, 13, TEXT)
		if crop_animate { // seletor de qual quadro editar
			bi := rl.Rectangle{ cx + cw - 22 - 180, ctrl_y - 3, 86, 24 }
			bf := rl.Rectangle{ cx + cw - 22 - 88,  ctrl_y - 3, 86, 24 }
			if clicked(bi) do crop_edit_end = false
			if clicked(bf) do crop_edit_end = true
			rl.DrawRectangleRounded(bi, 0.3, 5, !crop_edit_end ? rl.Color{40,78,52,255} : PANEL2)
			rl.DrawRectangleRounded(bf, 0.3, 5,  crop_edit_end ? rl.Color{92,42,38,255} : PANEL2)
			txt_c("Início", bi.x + bi.width/2, bi.y + 5, 12, CROP_START_COL)
			txt_c("Fim",    bf.x + bf.width/2, bf.y + 5, 12, CROP_END_COL)
		}
	}

	// área do vídeo (painel único). Pausado = frame + retângulos (editar); tocando = resultado.
	va_top := ctrl_y + (crop_tab == 1 ? f32(32) : f32(0))
	va := rl.Rectangle{ cx + 22, va_top, cw - 44, chh - (va_top - cy) - 100 }
	rl.DrawRectangleRec(va, rl.BLACK)
	ensure_tex(c)
	dur := max(sg.dur, 0.0001)
	if crop_play { // avança a reprodução (vídeo-só; loopa no fim)
		crop_play_t += rl.GetFrameTime()
		if crop_play_t >= dur do crop_play_t = 0
	}
	clip_frame(c, clamp(sg.in_off + crop_play_t*seg_speed(crop_bk_seg), 0, c.dur)) // frame no tempo atual
	cr := dec_content_rect(c)
	tff := min(va.width/cr.width, va.height/cr.height)
	fdw := cr.width*tff; fdh := cr.height*tff
	frx := va.x + (va.width-fdw)/2; fry := va.y + (va.height-fdh)/2

	if crop_play { // TOCANDO: mostra o resultado (região recortada ampliada), sem alças
		rx, ry, rw, rh: f32
		if crop_tab == 1 && crop_animate {
			f := crop_play_t/dur; f = f*f*(3 - 2*f) // smoothstep (== render)
			ax, ay, aw, ah := crop_norm(sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h)
			bx, by, bw, bh := crop_norm(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h)
			rx=ax+(bx-ax)*f; ry=ay+(by-ay)*f; rw=aw+(bw-aw)*f; rh=ah+(bh-ah)*f
		} else {
			rx, ry, rw, rh = crop_norm(sg.crop_x, sg.crop_y, sg.crop_w, sg.crop_h)
		}
		cav_w := min(va.width, va.height*proj_ar); cav_h := cav_w/proj_ar
		cav_x := va.x + (va.width-cav_w)/2; cav_y := va.y + (va.height-cav_h)/2
		rasp := (rw / rh) * clip_ar(c)
		dw := min(cav_w, cav_h*rasp); dh := dw/rasp
		if c.tex_ok do rl.DrawTexturePro(c.tex, { cr.x + rx*cr.width, cr.y + ry*cr.height, rw*cr.width, rh*cr.height },
			{ cav_x+(cav_w-dw)/2, cav_y+(cav_h-dh)/2, dw, dh }, {0,0}, 0, rl.WHITE)
	} else { // PAUSADO: frame inteiro + retângulos de edição
		if c.tex_ok do rl.DrawTexturePro(c.tex, cr, {frx,fry,fdw,fdh}, {0,0}, 0, rl.WHITE)
		if crop_tab == 0 {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, false, rl.WHITE)
		} else if !crop_animate {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, true, rl.WHITE)
		} else if crop_edit_end {
			crop_rect_editor(&sg.crop2_x, &sg.crop2_y, &sg.crop2_w, &sg.crop2_h, frx, fry, fdw, fdh, true, CROP_END_COL)
			crop_rect_ghost(sg.crop_x, sg.crop_y, sg.crop_w, sg.crop_h, frx, fry, fdw, fdh, CROP_START_COL)
		} else {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, true, CROP_START_COL)
			crop_rect_ghost(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h, frx, fry, fdw, fdh, CROP_END_COL)
		}
	}

	// --- transporte: play/pause + barra de posição + timecode (reproduz dentro do modal) ---
	tp_y := va.y + va.height + 8
	pb := rl.Rectangle{ cx + 22, tp_y, 30, 24 }
	if clicked(pb) do crop_play = !crop_play
	rl.DrawRectangleRounded(pb, 0.3, 5, hovered(pb) ? HOVER : PANEL2)
	pcx := pb.x + pb.width/2; pcy := pb.y + pb.height/2
	if crop_play { // ícone pausa
		rl.DrawRectangleRec({ pcx-5, pcy-6, 3.5, 12 }, TEXT); rl.DrawRectangleRec({ pcx+1.5, pcy-6, 3.5, 12 }, TEXT)
	} else { // ícone play (triângulo)
		rl.DrawTriangle({ pcx-4, pcy-6 }, { pcx-4, pcy+6 }, { pcx+6, pcy }, TEXT)
	}
	tc :: proc(s: f32) -> cstring { v := int(s + 0.001); return rl.TextFormat("%d:%02d", v/60, v%60) }
	tcw := f32(96)
	sb := rl.Rectangle{ pb.x + 42, tp_y + 10, cw - 44 - 42 - tcw, 5 }
	// `crop_drag < 0`: com uma alça do recorte agarrada o cursor pode sair do quadro (o
	// crop_rect_editor clampa o mouse, não solta o arrasto) e cruzar esta faixa, que começa
	// 8px abaixo da borda de baixo. Sem a guarda, arrastar a alça inferior para fora saltava
	// a reprodução do modal para outro ponto do clipe no meio do enquadramento — e com zoom
	// animado isso troca o quadro de referência que está sendo editado.
	if crop_drag < 0 && rl.IsMouseButtonPressed(.LEFT) && hovered({ sb.x-4, tp_y, sb.width+8, 24 }) do crop_play = false // scrub pausa
	if crop_drag < 0 && !crop_play && rl.IsMouseButtonDown(.LEFT) && hovered({ sb.x-4, tp_y, sb.width+8, 24 }) {
		crop_play_t = clamp((rl.GetMousePosition().x - sb.x)/sb.width, 0, 1) * dur
	}
	rl.DrawRectangleRounded(sb, 1, 4, LINE)
	kf := clamp(crop_play_t/dur, 0, 1)
	rl.DrawRectangleRounded({ sb.x, sb.y, kf*sb.width, sb.height }, 1, 4, ACCENT)
	rl.DrawCircleV({ sb.x + kf*sb.width, sb.y + 2 }, 6, ACCENT)
	txt(rl.TextFormat("%s / %s", tc(crop_play_t), tc(dur)), sb.x + sb.width + 12, tp_y + 4, 12, MUTED)

	// rodapé
	if ui_btn({ cx + 22, cy + chh - 46, 116, 32 }, "Redefinir", false) {
		if crop_tab == 1 {
			sg.crop_x=0; sg.crop_y=0; sg.crop_w=1; sg.crop_h=1
			crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h)
			sg.crop2_x=sg.crop_x; sg.crop2_y=sg.crop_y; sg.crop2_w=sg.crop_w; sg.crop2_h=sg.crop_h
		} else {
			sg.crop_x=0; sg.crop_y=0; sg.crop_w=1; sg.crop_h=1
		}
	}
	if ui_btn({ cx + cw - 224, cy + chh - 46, 100, 32 }, "Cancelar", false) { crop_modal_cancel(); return }
	if ui_btn({ cx + cw - 114, cy + chh - 46, 92, 32 }, "OK", true) { crop_modal_ok(); return }
}
