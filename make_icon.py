from PIL import Image, ImageDraw

S = 1024  # supersample; downscale no final p/ bordas suaves

# --- fundo: gradiente vertical teal (cor de destaque do app) ---
top = (52, 220, 200)   # teal claro
bot = (18, 116, 106)   # teal profundo
grad = Image.new("RGB", (1, S))
gp = grad.load()
for y in range(S):
    t = y / (S - 1)
    gp[0, y] = (
        int(top[0] * (1 - t) + bot[0] * t),
        int(top[1] * (1 - t) + bot[1] * t),
        int(top[2] * (1 - t) + bot[2] * t),
    )
img = grad.resize((S, S)).convert("RGBA")
d = ImageDraw.Draw(img)

# NOTA: as antigas "tiras de filme" nas LATERAIS foram removidas — elas espremiam a área
# colorida do meio num retângulo estreito e ALTO, dando a impressão de ícone esticado na
# vertical. Agora o teal preenche o quadrado inteiro (leitura claramente quadrada, estilo
# CapCut). Uma dica sutil de "filme" fica nos furos discretos em CIMA e EMBAIXO.

# --- furos de filme discretos nas bordas de cima e de baixo (não estreitam a horizontal) ---
hole_w = int(S * 0.052)
hole_h = int(S * 0.028)
n_holes = 7
margin = S * 0.10                      # recuo das laterais p/ os furos não colarem no canto
span = S - 2 * margin
step = span / n_holes
for i in range(n_holes):
    cxh = margin + step * (i + 0.5)
    for cyh in (S * 0.052, S - S * 0.052):
        d.rounded_rectangle(
            [cxh - hole_w / 2, cyh - hole_h / 2, cxh + hole_w / 2, cyh + hole_h / 2],
            radius=hole_h * 0.45, fill=(255, 255, 255, 55),
        )

# --- play branco no centro (LEVEMENTE mais largo que alto p/ não puxar pra vertical) ---
cx, cy = S * 0.53, S * 0.5   # cx um tico à direita compensa o centroide (base à esquerda)
tw = S * 0.34                # largura do triângulo
th = S * 0.30                # altura  (< largura -> leitura horizontal, "play")
tri = [(cx - tw / 2, cy - th / 2), (cx - tw / 2, cy + th / 2), (cx + tw / 2, cy)]
# leve sombra p/ dar profundidade
sh = [(x + S * 0.012, y + S * 0.012) for x, y in tri]
d.polygon(sh, fill=(0, 40, 36, 90))
d.polygon(tri, fill=(255, 255, 255, 255))

# --- máscara de canto arredondado (squircle suave, estilo dos ícones do Windows 11) ---
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
img.putalpha(mask)

OUT = r"C:\Users\Adm\Desktop\video editor"
sizes = [16, 24, 32, 48, 64, 128, 256]
# ICO deve partir da MAIOR imagem — o Pillow reduz p/ cada tamanho (ignora tamanhos > origem).
base = img.resize((256, 256), Image.LANCZOS)
base.save(OUT + r"\icon.ico", format="ICO", sizes=[(s, s) for s in sizes])
# PNG 64x64 p/ o rl.SetWindowIcon em runtime (via #load)
img.resize((64, 64), Image.LANCZOS).save(OUT + r"\icon.png")
print("gerado: icon.ico (" + ",".join(str(s) for s in sizes) + ") + icon.png 64x64")
