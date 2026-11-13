#!/usr/bin/env python3
"""Crown Racer Cards — image renderer for the GitHub Actions runner.
Run from the repo root: python3 gen/render.py
Reads masters from gen/masters/, tiers from nft-contract/assignment.json,
writes nft/images/<id>.png for all 2,222 tokens. Deterministic per token.
"""
import json, os, random
from concurrent.futures import ProcessPoolExecutor
from PIL import Image, ImageDraw, ImageFont, ImageEnhance

BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
CW, CH = 600, 840
TIERS = ["Rookie", "Pro", "Nitro", "Champion"]
FRAME = [(46, 204, 113), (52, 152, 219), (230, 126, 34), (246, 184, 30)]
DARK = [(10, 40, 24), (8, 26, 48), (46, 24, 4), (54, 40, 4)]
MASTERS = {}
THEMES = [
    ("Neon Pit",      (0, 255, 190)),
    ("Golden Arena",  (255, 190, 40)),
    ("Midnight GP",   (40, 60, 200)),
    ("Rain Circuit",  (70, 160, 220)),
    ("Sunset Strip",  (255, 110, 60)),
    ("Emerald Dome",  (30, 200, 90)),
    ("Crimson Mile",  (230, 40, 60)),
    ("Arctic Straight", (190, 230, 255)),
]
TINTS = [(255, 120, 120), (120, 200, 255), (255, 220, 120),
         (160, 255, 180), (220, 160, 255), (255, 170, 90)]

def load_master(tier):
    if tier not in MASTERS:
        MASTERS[tier] = Image.open(os.path.join("gen", "masters", tier + ".png")).convert("RGB")
    return MASTERS[tier]

def blend(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def bg_grad(w, h, top, bottom):
    bg = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(bg)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=blend(top, bottom, y / h))
    return bg

def render(job):
    token_id, tier_code = job
    rnd = random.Random(f"crown-card-{token_id}")
    theme_name, theme_tint = THEMES[rnd.randrange(len(THEMES))]
    bright = 0.92 + rnd.random() * 0.16
    color = 0.88 + rnd.random() * 0.26
    contrast = 0.94 + rnd.random() * 0.14
    tint = TINTS[rnd.randrange(len(TINTS))]
    tint_alpha = 0.05 + rnd.random() * 0.09

    tier = TIERS[tier_code].lower()
    frame = FRAME[tier_code]
    card = bg_grad(CW, CH, blend((18, 24, 38), theme_tint, 0.18),
                   blend(DARK[tier_code], theme_tint, 0.12))
    m = load_master(tier)
    w, h = m.size
    char = m.crop((0, 0, w, int(h * 0.80)))
    char = ImageEnhance.Brightness(char).enhance(bright)
    char = ImageEnhance.Color(char).enhance(color)
    char = ImageEnhance.Contrast(char).enhance(contrast)
    char = Image.blend(char, Image.new("RGB", char.size, tint), tint_alpha)
    cw = CW - 68
    chh = int(char.size[1] * cw / char.size[0])
    maxh = CH - 200
    if chh > maxh:
        chh = maxh
        cw = int(char.size[0] * chh / char.size[1])
    card.paste(char.resize((cw, chh), Image.LANCZOS),
               ((CW - cw) // 2, max(20, (maxh - chh) // 2 + 20)))
    d = ImageDraw.Draw(card)
    for t in range(7):
        d.rectangle([t, t, CW - 1 - t, CH - 1 - t], outline=frame)
    f_big = ImageFont.truetype(BOLD, 52)
    f_mid = ImageFont.truetype(BOLD, 29)
    f_small = ImageFont.truetype(BOLD, 20)
    d.rectangle([0, CH - 138, CW, CH], fill=(5, 8, 14))
    for t in range(3):
        d.line([(0, CH - 138 + t), (CW, CH - 138 + t)], fill=frame)
    d.text((28, CH - 118), TIERS[tier_code].upper(), font=f_big, fill=frame)
    d.text((28, CH - 54), "CROWN RACER CARDS", font=f_mid, fill=(220, 226, 235))
    serial = f"#{token_id:04d}"
    d.text((CW - 28 - d.textlength(serial, font=f_mid), CH - 54), serial,
           font=f_mid, fill=(220, 226, 235))
    d.text((28, 24), "CROWN RACE", font=f_mid, fill=(240, 244, 250))
    d.text((CW - 28 - d.textlength(theme_name.upper(), font=f_small), 30),
           theme_name.upper(), font=f_small, fill=(200, 208, 220))
    card.save(os.path.join("nft", "images", f"{token_id}.png"), optimize=True)
    return token_id

def main():
    os.makedirs(os.path.join("nft", "images"), exist_ok=True)
    assignment = json.load(open(os.path.join("nft-contract", "assignment.json")))
    jobs = [(i, 0) for i in range(1, 501)] + \
           [(501 + i, c) for i, c in enumerate(assignment)]
    with ProcessPoolExecutor(max_workers=4) as ex:
        done = list(ex.map(render, jobs))
    print(f"rendered {len(done)} images")

if __name__ == "__main__":
    main()
