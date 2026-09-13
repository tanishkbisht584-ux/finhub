"""Rasterise the FinSwipe mark and install every icon the app/admin ship.

    python3 docs/brand/render.py

No cairosvg/inkscape on the dev box; Chrome is, and it bakes Georgia glyphs so the
SVG <text> never depends on the viewer's fonts. PIL then resizes the 1024 masters
into every destination. Re-run after any change to mark.svg / mark-mono.svg.

Masters (land next to this file):
  icon-foreground-1024.png  adaptive-icon foreground, transparent, mark inside the 66% safe circle
  icon-mono-1024.png        adaptive-icon monochrome layer, same box, white on transparent
  icon-full-1024.png        mark on clay black (Play 512 source, previews)
  mark-1024.png             mark filling the canvas, transparent (splash, in-app asset, web/legacy icons)
  mark-mono-1024.png        white mark filling the canvas, transparent (notification icon)
  play-icon-512.png         Play Store listing icon
  play-feature-1024x500.png Play Store feature graphic (mark + FinSwipe + tagline)

Installed:
  app/android/.../mipmap-*/ic_launcher.png, ic_launcher_foreground.png, ic_launcher_monochrome.png
  app/android/.../drawable-*/splash_mark.png (160 dp), ic_notification.png (24 dp)
  app/web/favicon.png, app/web/icons/Icon-{192,512}.png, Icon-maskable-{192,512}.png
  app/assets/brand/mark.png (+2.0x, 3.0x)
  admin/finswipe.ico
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
RES = REPO / "app" / "android" / "app" / "src" / "main" / "res"
WEB = REPO / "app" / "web"
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
BG = "#0E100F"
BG_RGBA = (0x0E, 0x10, 0x0F, 255)
MARK = (HERE / "mark.svg").read_text(encoding="utf-8")
MONO = (HERE / "mark-mono.svg").read_text(encoding="utf-8")
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def svg_at(svg: str, w: int, h: int) -> str:
    """Re-size an inline SVG by swapping its width/height attributes."""
    return svg.replace('width="100" height="100"', f'width="{w}" height="{h}"', 1)


def page(body: str, w: int, h: int, bg: str | None) -> str:
    bgcss = f"background:{bg}" if bg else "background:transparent"
    return (f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;width:{w}px;height:{h}px;{bgcss};'
            f'display:flex;align-items:center;justify-content:center;overflow:hidden}}svg{{display:block}}</style>{body}')


def shoot(name: str, html: str, w: int, h: int, transparent: bool) -> None:
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "p.html"
        src.write_text(html, encoding="utf-8")
        out = HERE / name
        args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
                f"--user-data-dir={td}/profile", "--force-device-scale-factor=1",
                f"--window-size={w},{h}", f"--screenshot={out}"]
        if transparent:
            args.append("--default-background-color=00000000")
        args.append(src.as_uri())
        subprocess.run(args, check=True, capture_output=True)
        print(f"{name}: {out.stat().st_size} bytes")


def masters() -> None:
    # Adaptive icon: 1024 canvas = 108dp; safe circle = 66dp -> 626px. Mark box 560px sits inside it.
    box = 560
    shoot("icon-foreground-1024.png", page(svg_at(MARK, box, box), 1024, 1024, None), 1024, 1024, True)
    shoot("icon-mono-1024.png", page(svg_at(MONO, box, box), 1024, 1024, None), 1024, 1024, True)
    shoot("icon-full-1024.png", page(svg_at(MARK, box, box), 1024, 1024, BG), 1024, 1024, False)
    shoot("mark-1024.png", page(svg_at(MARK, 1024, 1024), 1024, 1024, None), 1024, 1024, True)
    shoot("mark-mono-1024.png", page(svg_at(MONO, 1024, 1024), 1024, 1024, None), 1024, 1024, True)
    shoot("play-icon-512.png", page(svg_at(MARK, 300, 300), 512, 512, BG), 512, 512, False)
    feature = (
        '<div style="display:flex;align-items:center;gap:72px">'
        + svg_at(MARK, 260, 260)
        + '<div style="font-family:Georgia,\'Noto Serif\',serif;color:#E8E6E3">'
        '<div style="font-size:64px;font-weight:700;letter-spacing:-.01em">'
        '<span style="color:#3ECF8E">Fin</span>Swipe</div>'
        '<div style="font-size:26px;font-style:italic;color:#9BA09C;margin-top:14px;max-width:460px;line-height:1.35">'
        'Understand what market news means in 15 seconds.</div></div></div>'
    )
    shoot("play-feature-1024x500.png", page(feature, 1024, 500, BG), 1024, 500, False)


def fit(src: Image.Image, size: int) -> Image.Image:
    return src.resize((size, size), Image.LANCZOS)


def on_bg(mark: Image.Image, size: int, scale: float) -> Image.Image:
    """Mark centred on clay black, occupying `scale` of the square."""
    out = Image.new("RGBA", (size, size), BG_RGBA)
    inner = max(1, round(size * scale))
    m = fit(mark, inner)
    off = (size - inner) // 2
    out.alpha_composite(m, (off, off))
    return out


def save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(f"  -> {path.relative_to(REPO)} {img.size[0]}px")


def install() -> None:
    mark = Image.open(HERE / "mark-1024.png").convert("RGBA")
    mono = Image.open(HERE / "mark-mono-1024.png").convert("RGBA")
    fg = Image.open(HERE / "icon-foreground-1024.png").convert("RGBA")
    fg_mono = Image.open(HERE / "icon-mono-1024.png").convert("RGBA")

    for name, k in DENSITIES.items():
        mip, drw = RES / f"mipmap-{name}", RES / f"drawable-{name}"
        save(on_bg(mark, round(48 * k), 0.72), mip / "ic_launcher.png")          # legacy launcher
        save(fit(fg, round(108 * k)), mip / "ic_launcher_foreground.png")        # adaptive layers
        save(fit(fg_mono, round(108 * k)), mip / "ic_launcher_monochrome.png")
        save(fit(mark, round(160 * k)), drw / "splash_mark.png")                 # launch_background
        save(fit(mono, round(24 * k)), drw / "ic_notification.png")              # FCM small icon

    save(on_bg(mark, 32, 0.84), WEB / "favicon.png")
    for n in (192, 512):
        save(on_bg(mark, n, 0.72), WEB / "icons" / f"Icon-{n}.png")
        save(on_bg(mark, n, 0.6), WEB / "icons" / f"Icon-maskable-{n}.png")

    brand = REPO / "app" / "assets" / "brand"
    save(fit(mark, 96), brand / "mark.png")
    save(fit(mark, 192), brand / "2.0x" / "mark.png")
    save(fit(mark, 288), brand / "3.0x" / "mark.png")

    ico = REPO / "admin" / "finswipe.ico"
    on_bg(mark, 48, 0.84).save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
    print(f"  -> {ico.relative_to(REPO)}")


def main() -> None:
    masters()
    install()


if __name__ == "__main__":
    sys.exit(main())
