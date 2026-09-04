"""Rasterise the FinSwipe mark/lockup with headless Chrome.

    python docs/brand/render.py

No cairosvg/inkscape on the dev box; Chrome is, and it bakes Georgia/Consolas
glyphs so the SVG <text> never depends on the viewer's fonts. Every output
lands next to this file. Sizes:

  icon-foreground-1024.png  adaptive-icon foreground, transparent, mark inside the 66% safe circle
  icon-mono-1024.png        adaptive-icon monochrome layer, white on transparent
  icon-full-1024.png        mark on clay black (legacy launcher / Play 512 source)
  play-icon-512.png         Play Store listing icon
  play-feature-1024x500.png Play Store feature graphic (lockup + tagline)
  splash-mark-512.png       transparent mark for launch_background.xml
  lockup-2x.png / -3x.png   in-app wordmark-free mark (200 logical px wide)
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
BG = "#0E100F"
MARK = (HERE / "mark.svg").read_text(encoding="utf-8")
MONO = (HERE / "mark-mono.svg").read_text(encoding="utf-8")


def svg_at(svg: str, w: int, h: int) -> str:
    """Re-size an inline SVG by swapping its width/height attributes."""
    return svg.replace('width="100" height="100"', f'width="{w}" height="{h}"', 1).replace(
        'width="100" height="126"', f'width="{w}" height="{h}"', 1)


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


def main() -> None:
    # Adaptive icon: 1024 canvas = 108dp; safe circle = 66dp -> 626px. Mark box 560px sits inside it.
    box = 560
    shoot("icon-foreground-1024.png", page(svg_at(MARK, box, box), 1024, 1024, None), 1024, 1024, True)
    shoot("icon-mono-1024.png", page(svg_at(MONO, box, box), 1024, 1024, None), 1024, 1024, True)
    shoot("icon-full-1024.png", page(svg_at(MARK, box, box), 1024, 1024, BG), 1024, 1024, False)
    shoot("play-icon-512.png", page(svg_at(MARK, 300, 300), 512, 512, BG), 512, 512, False)
    shoot("splash-mark-512.png", page(svg_at(MARK, 512, 512), 512, 512, None), 512, 512, True)
    shoot("lockup-2x.png", page(svg_at(MARK, 400, 400), 400, 400, None), 400, 400, True)
    shoot("lockup-3x.png", page(svg_at(MARK, 600, 600), 600, 600, None), 600, 600, True)

    feature = (
        '<div style="display:flex;align-items:center;gap:72px">'
        + svg_at(MARK, 260, 260)
        + '<div style="font-family:Georgia,\'Noto Serif\',serif;color:#E8E6E3">'
        '<div style="font-size:64px;font-weight:700;letter-spacing:-.01em">FinSwipe</div>'
        '<div style="font-size:26px;font-style:italic;color:#9BA09C;margin-top:14px;max-width:460px;line-height:1.35">'
        'Understand what market news means in 15 seconds.</div></div></div>'
    )
    shoot("play-feature-1024x500.png", page(feature, 1024, 500, BG), 1024, 500, False)


if __name__ == "__main__":
    sys.exit(main())
