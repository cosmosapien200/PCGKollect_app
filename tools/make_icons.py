"""Generate app icons, splash images and repo logos from the two source logos.

    python tools/make_icons.py <logo_icon.png> <logo_full.png>

The sources are black artwork on an off-white, vignetted background. They are converted
to clean black-on-transparent (alpha from darkness, background cut off), cropped, and
written to:
  assets/branding/            logo_mark.png, logo_full.png (+ *_white.png for dark UIs)
  android/app/src/main/res/   legacy launcher icons, adaptive foreground, splash bitmaps
"""
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android/app/src/main/res")
BRAND = os.path.join(ROOT, "assets/branding")
DENS = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def clean(path, lo=120, hi=200):
    """Black artwork -> RGBA black with alpha ramp: L<=lo opaque, L>=hi transparent."""
    g = Image.open(path).convert("L")
    a = g.point(lambda v: 255 if v <= lo else 0 if v >= hi else int(255 * (hi - v) / (hi - lo)))
    a = a.crop(a.getbbox())
    img = Image.new("RGBA", a.size, (0, 0, 0, 255))
    img.putalpha(a)
    return img


def recolor(img, rgb):
    out = Image.new("RGBA", img.size, rgb + (255,))
    out.putalpha(img.getchannel("A"))
    return out


def fit(img, size, frac, bg=None):
    """Center img in a size x size canvas, scaled so its longer side is frac * size."""
    canvas = Image.new("RGBA", (size, size), bg or (0, 0, 0, 0))
    s = frac * size / max(img.size)
    r = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
    canvas.alpha_composite(r, ((size - r.width) // 2, (size - r.height) // 2))
    return canvas


def save(img, *parts):
    p = os.path.join(*parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p, optimize=True)
    print(p, img.size)


def main(icon_src, full_src):
    mark = clean(icon_src)
    full = clean(full_src)
    os.makedirs(BRAND, exist_ok=True)
    save(fit(mark, 1024, 0.9), BRAND, "logo_mark.png")
    save(recolor(fit(mark, 1024, 0.9), (255, 255, 255)), BRAND, "logo_mark_white.png")
    w = 1200
    s = w * 0.92 / full.width
    fr = full.resize((round(full.width * s), round(full.height * s)), Image.LANCZOS)
    canvas = Image.new("RGBA", (w, fr.height + 80), (0, 0, 0, 0))
    canvas.alpha_composite(fr, ((w - fr.width) // 2, 40))
    save(canvas, BRAND, "logo_full.png")
    save(recolor(canvas, (255, 255, 255)), BRAND, "logo_full_white.png")

    white = (255, 255, 255, 255)
    for d, k in DENS.items():
        # legacy launcher (pre-Android 8): white rounded square / circle with the mark
        n = round(48 * k)
        sq = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(sq).rounded_rectangle((0, 0, n - 1, n - 1), radius=round(n * 0.18), fill=white)
        sq.alpha_composite(fit(mark, n, 0.72))
        save(sq, RES, f"mipmap-{d}", "ic_launcher.png")
        rd = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(rd).ellipse((0, 0, n - 1, n - 1), fill=white)
        rd.alpha_composite(fit(mark, n, 0.62))
        save(rd, RES, f"mipmap-{d}", "ic_launcher_round.png")
        # adaptive foreground: 108 dp canvas, artwork inside the 66 dp safe zone
        save(fit(mark, round(108 * k), 0.56), RES, f"mipmap-{d}", "ic_launcher_foreground.png")
        # Android 12+ splash icon: 288 dp canvas, artwork inside the 192 dp circle
        save(fit(mark, round(288 * k), 0.46), RES, f"drawable-{d}", "splash_icon.png")
        # pre-12 splash (launch_background bitmap): the full logo, 200 dp wide
        bw = round(200 * k)
        save(fit(full, bw, 0.95), RES, f"drawable-{d}", "splash_full.png")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
