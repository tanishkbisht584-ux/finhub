"""Build and install every FinFlick icon from the brand sheet (20 Sep 2026).

    py -3 docs/brand/render.py

Source: finflick-sheet.jpg (Tanis's approved sheet: app icon, wordmark, single-
colour mark). The mark is cut from the single-colour panel (dark on white) as
an alpha mask — cleanest edges on the sheet — then filled green or white. The
sheet is a ~200 px raster, which covers every size the app ships (launcher
icons top out at 192 px; the 640 px splash is soft but fine). Replace the
sheet with a vector export when one exists and re-run.

Masters (land next to this file):
  mark-1024.png             green mark, transparent (splash, in-app asset, web icons)
  mark-mono-1024.png        white mark, transparent (notification icon, adaptive mono layer)
  icon-foreground-1024.png  adaptive-icon foreground: mark inside the 66% safe circle
  icon-mono-1024.png        adaptive-icon monochrome layer, same box
  icon-full-1024.png        mark on clay black (previews)
  play-icon-512.png         Play Store listing icon
  play-feature-1024x500.png Play Store feature graphic (mark + FinFlick + tagline)
Installed:
  app/android/.../mipmap-*/ic_launcher.png, ic_launcher_foreground.png, ic_launcher_monochrome.png
  app/android/.../drawable-*/splash_mark.png (160 dp), ic_notification.png (24 dp)
  app/web/favicon.png, app/web/icons/Icon-{192,512}.png, Icon-maskable-{192,512}.png
  app/assets/brand/mark.png (+2.0x, 3.0x)
  admin/finflick.ico, admin/logo.png
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
RES = REPO / "app" / "android" / "app" / "src" / "main" / "res"
WEB = REPO / "app" / "web"
SHEET = HERE / "finflick-sheet.jpg"
MONO_BOX = (120, 420, 320, 580)   # single-colour application panel (dark mark on white)
ICON_BOX = (130, 95, 340, 305)    # app-icon panel, used only to sample the green
BG_RGBA = (0x0E, 0x10, 0x0F, 255)
INK = (0xE8, 0xE6, 0xE3, 255)
INK_DIM = (0x9B, 0xA0, 0x9C, 255)
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
FONTS = Path(r"C:\Windows\Fonts")


def brand_green(sheet: Image.Image) -> tuple[int, int, int]:
    """Median of the clearly-green pixels inside the app-icon panel."""
    px = list(sheet.crop(ICON_BOX).getdata())
    greens = sorted(p for p in px if p[1] > p[0] + 40 and p[1] > p[2] + 20)
    if not greens:
        return (0x3E, 0xCF, 0x8E)
    return greens[len(greens) // 2][:3]


def mask_1024(sheet: Image.Image) -> Image.Image:
    """Alpha mask of the mark: darkness of the single-colour panel, soft
    threshold, trimmed and centred on a square 1024 canvas with 6% padding."""
    g = sheet.crop(MONO_BOX).convert("L")
    a = g.point(lambda v: max(0, min(255, round((215 - v) * 255 / 140))))
    bbox = a.point(lambda v: 255 if v > 40 else 0).getbbox()
    a = a.crop(bbox)
    side = max(a.size)
    sq = Image.new("L", (side, side), 0)
    sq.paste(a, ((side - a.width) // 2, (side - a.height) // 2))
    inner = round(1024 * 0.88)
    big = sq.resize((inner, inner), Image.LANCZOS)
    out = Image.new("L", (1024, 1024), 0)
    out.paste(big, ((1024 - inner) // 2, (1024 - inner) // 2))
    return out


def filled(mask: Image.Image, rgb: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGBA", mask.size, rgb + (255,))
    img.putalpha(mask)
    return img


def fit(src: Image.Image, size: int) -> Image.Image:
    return src.resize((size, size), Image.LANCZOS)


def boxed(mark: Image.Image, canvas: int, inner: int, bg: tuple | None) -> Image.Image:
    out = Image.new("RGBA", (canvas, canvas), bg or (0, 0, 0, 0))
    out.alpha_composite(fit(mark, inner), ((canvas - inner) // 2, (canvas - inner) // 2))
    return out


def on_bg(mark: Image.Image, size: int, scale: float) -> Image.Image:
    return boxed(mark, size, max(1, round(size * scale)), BG_RGBA)


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), size)


def feature(mark: Image.Image, green: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGBA", (1024, 500), BG_RGBA)
    img.alpha_composite(fit(mark, 260), (110, 120))
    d = ImageDraw.Draw(img)
    bold, ital = font("georgiab.ttf", 64), font("georgiai.ttf", 26)
    x, y = 430, 150
    d.text((x, y), "Fin", font=bold, fill=green + (255,))
    d.text((x + d.textlength("Fin", font=bold), y), "Flick", font=bold, fill=INK)
    d.text((x, y + 92), "Understand what market news means", font=ital, fill=INK_DIM)
    d.text((x, y + 126), "in 15 seconds.", font=ital, fill=INK_DIM)
    return img


def admin_logo(mark: Image.Image) -> Image.Image:
    """Sidebar logo for Streamlit: mark + 'FinFlick Admin', transparent."""
    img = Image.new("RGBA", (440, 96), (0, 0, 0, 0))
    img.alpha_composite(fit(mark, 80), (8, 8))
    d = ImageDraw.Draw(img)
    d.text((104, 26), "FinFlick Admin", font=font("georgiab.ttf", 36), fill=INK)
    return img


def save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(f"  -> {path.relative_to(REPO)} {img.size[0]}px")


def main() -> None:
    sheet = Image.open(SHEET).convert("RGB")
    green = brand_green(sheet)
    print("brand green", "#%02X%02X%02X" % green)
    mask = mask_1024(sheet)
    mark, mono = filled(mask, green), filled(mask, (255, 255, 255))
    mark.save(HERE / "mark-1024.png")
    mono.save(HERE / "mark-mono-1024.png")
    fg, fg_mono = boxed(mark, 1024, 560, None), boxed(mono, 1024, 560, None)
    fg.save(HERE / "icon-foreground-1024.png")
    fg_mono.save(HERE / "icon-mono-1024.png")
    boxed(mark, 1024, 560, BG_RGBA).save(HERE / "icon-full-1024.png")
    boxed(mark, 512, 300, BG_RGBA).save(HERE / "play-icon-512.png")
    feature(mark, green).save(HERE / "play-feature-1024x500.png")

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
    ico = REPO / "admin" / "finflick.ico"
    on_bg(mark, 48, 0.84).save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
    print(f"  -> {ico.relative_to(REPO)}")
    save(admin_logo(mark), REPO / "admin" / "logo.png")


if __name__ == "__main__":
    main()
