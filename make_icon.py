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

# --- tiras de filme nas laterais (faixa translúcida escura + furos) ---
dark = (14, 62, 57, 255)
strip_w = int(S * 0.14)
d.rectangle([0, 0, strip_w, S], fill=dark)
d.rectangle([S - strip_w, 0, S, S], fill=dark)
hole_w = int(strip_w * 0.5)
hole_h = int(S * 0.085)
gap = (S - 5 * hole_h) / 6
for i in range(5):
    y0 = gap + i * (hole_h + gap)
    for cx in (strip_w * 0.5, S - strip_w * 0.5):
        d.rounded_rectangle(
            [cx - hole_w / 2, y0, cx + hole_w / 2, y0 + hole_h],
            radius=hole_w * 0.28, fill=(230, 245, 242, 255),
        )

# --- play branco no centro ---
# triângulo LEVEMENTE mais largo que alto (largura 1.85r x altura 1.7r) p/ não "puxar" a
# leitura do ícone pra vertical; cx deslocado p/ compensar o centroide (base à esquerda).
cx, cy = S * 0.535, S * 0.5
r = S * 0.20
hh = r * 0.85  # meia-altura (< r deixa o triângulo mais largo que alto)
tri = [(cx - r * 0.85, cy - hh), (cx - r * 0.85, cy + hh), (cx + r, cy)]
# leve sombra p/ dar profundidade
sh = [(x + S * 0.012, y + S * 0.012) for x, y in tri]
d.polygon(sh, fill=(0, 40, 36, 90))
d.polygon(tri, fill=(255, 255, 255, 255))

# --- máscara de canto arredondado (o app usa cantos arredondados) ---
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.19), fill=255)
img.putalpha(mask)

OUT = r"C:\Users\Adm\Desktop\video editor"
sizes = [16, 24, 32, 48, 64, 128, 256]
# ICO deve partir da MAIOR imagem — o Pillow reduz p/ cada tamanho (ignora tamanhos > origem).
base = img.resize((256, 256), Image.LANCZOS)
base.save(OUT + r"\icon.ico", format="ICO", sizes=[(s, s) for s in sizes])
# PNG 64x64 p/ o rl.SetWindowIcon em runtime (via #load)
img.resize((64, 64), Image.LANCZOS).save(OUT + r"\icon.png")
print("gerado: icon.ico (" + ",".join(str(s) for s in sizes) + ") + icon.png 64x64")
