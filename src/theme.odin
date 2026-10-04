package main

import rl "vendor:raylib"

// ---------- tema: cores e tipografia da interface ----------
// Toda cor de "chrome" (fundos, modais, menus, controles, estados) sai daqui. Cor nova na
// UI = token novo aqui, não literal no meio do draw — literais soltos foram o que deixou
// modais, menus e cards cada um num cinza ligeiramente diferente.
// Ficam FORA do tema (literais de propósito): a arte dos ícones de efeitos/transições,
// o HUD de profiler (debug), os presets de cor do texto do usuário e as cores do vídeo.

// superfícies, do mais fundo ao mais alto. Três níveis de painel mantêm a separação sem
// depender de bordas pesadas.
TOPBAR   :: rl.Color{ 15, 18, 24, 255 }
BG       :: rl.Color{ 18, 21, 27, 255 }
SUNK     :: rl.Color{ 20, 23, 29, 255 }  // rebaixado: trilho de scroll, régua, faixas de fundo
PANEL2   :: rl.Color{ 26, 30, 38, 255 }
SURFACE  :: rl.Color{ 30, 34, 42, 255 }  // cartão de modal
POPUP    :: rl.Color{ 30, 34, 42, 250 }  // menus, popups (mesmo tom do modal, quase opaco)
TOOLTIP  :: rl.Color{ 16, 19, 24, 242 }
PANEL    :: rl.Color{ 34, 39, 48, 255 }
CONTROL  :: rl.Color{ 42, 47, 58, 255 }  // fundo de botão/chip/campo em repouso
SEL_BG   :: rl.Color{ 40, 50, 64, 255 }  // linha/badge selecionado (não-accent)
HOVER    :: rl.Color{ 51, 58, 71, 255 }
TRACK_BG :: rl.Color{ 50, 55, 66, 255 }  // trilho de barra de progresso
GRIP     :: rl.Color{ 72, 78, 90, 255 }  // pegador/scroll em repouso
SCRIM    :: rl.Color{ 0, 0, 0, 150 }     // escurece o fundo atrás de modal

// linhas
LINE     :: rl.Color{ 62, 69, 84, 255 }
SEP      :: rl.Color{ 49, 55, 67, 190 }  // separador sutil entre trilhas

// texto
TEXT     :: rl.Color{ 239, 243, 248, 255 }
MUTED    :: rl.Color{ 157, 168, 186, 255 }
DISABLED :: rl.Color{ 96, 102, 114, 255 }
INK      :: rl.Color{ 18, 22, 28, 255 }  // texto/ícone escuro sobre fundo claro (accent, âmbar)
KNOB     :: rl.Color{ 225, 230, 238, 255 } // botão de slider

// marca
ACCENT    :: rl.Color{ 45, 212, 192, 255 }
ACCENT_D  :: rl.Color{ 25, 143, 130, 255 }
ACCENT_BG :: rl.Color{ 31, 50, 54, 255 } // fundo de aba ativa
PLAYHEAD  :: rl.Color{ 236, 72, 60, 255 }

// estados
DANGER   :: rl.Color{ 224, 96, 88, 255 }
DANGER_D :: rl.Color{ 170, 60, 60, 255 }  // fundo de estado "ligado" vermelho (trilha muda)
WARN     :: rl.Color{ 245, 202, 84, 255 }
LOCKED   :: rl.Color{ 210, 160, 50, 255 }
SUCCESS  :: rl.Color{ 90, 200, 120, 255 }
INFO     :: rl.Color{ 120, 190, 230, 255 }
SELECT   :: rl.Color{ 140, 184, 244, 255 } // seleção por retângulo (marquee) e marcados

// timeline
LANE_A        :: rl.Color{ 28, 32, 40, 255 } // trilhas alternadas
LANE_B        :: rl.Color{ 30, 34, 42, 255 }
CLIP          :: rl.Color{ 55, 90, 113, 255 }
CLIP_HDR      :: rl.Color{ 71, 115, 140, 255 }
AUDIOCLIP     :: rl.Color{ 46, 78, 68, 255 }
TEXTCLIP      :: rl.Color{ 66, 54, 86, 255 }
TEXTCLIP_EDGE :: rl.Color{ 105, 84, 132, 255 }
TEXTCLIP_INK  :: rl.Color{ 214, 204, 236, 255 }
TRACK_VIDEO   :: rl.Color{ 76, 128, 174, 255 }
TRACK_AUDIO   :: rl.Color{ 70, 148, 116, 255 }
TRACK_HIDDEN  :: rl.Color{ 80, 100, 130, 255 }
WAVE          :: rl.Color{ 95, 180, 150, 255 }
WAVE_BG       :: rl.Color{ 24, 46, 40, 255 }
WAVE_BASE     :: rl.Color{ 70, 100, 92, 255 }

// preview
PV_BACK  :: rl.Color{ 31, 35, 43, 255 }    // fundo do painel FORA do quadro de saída (não é preto:
                                           // separa à vista o que é vídeo do que é só sobra do painel)
PV_EDGE  :: rl.Color{ 104, 114, 132, 235 } // moldura do quadro de saída

// inspetor
INSP_HDR     :: rl.Color{ 42, 48, 59, 255 } // um degrau acima do PANEL: cabeçalho destacado sem borda
INSP_HDR_HOT :: rl.Color{ 49, 56, 69, 255 }

// mesma cor com outra opacidade (0..255). `fa` (preview.odin) MULTIPLICA a opacidade;
// esta SUBSTITUI — é a que os tokens usam p/ variantes translúcidas.
alpha :: proc(c: rl.Color, a: u8) -> rl.Color { return { c.r, c.g, c.b, a } }

// ---------- escala tipográfica ----------
// Cinco tamanhos (antes eram oito soltos, 10..18). O txt() ainda multiplica por g_us.
FS_XS :: 11 // legenda: régua, selos, nomes de mídia, dicas
FS_SM :: 12 // secundário: rótulos de controles densos
FS_MD :: 13 // corpo: texto padrão de painéis, menus, formulários
FS_LG :: 15 // título: cabeçalho de modal/painel, timecode
FS_XL :: 18 // destaque
