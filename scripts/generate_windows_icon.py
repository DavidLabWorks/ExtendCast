from pathlib import Path

from PIL import Image, ImageChops, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Shared" / "Branding" / "ExtendCastIcon.png"
PNG_OUT = ROOT / "Desktop" / "icon_256x256.png"
ICO_OUT = ROOT / "Desktop" / "appicon.ico"

SIZES = (16, 24, 32, 40, 48, 64, 128, 256)


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def make_base_icon() -> Image.Image:
    size = 256
    source = Image.open(SOURCE).convert("RGBA")
    clipped = source.resize((size, size), Image.Resampling.LANCZOS)
    mask = rounded_rect_mask(size, 44)
    clipped.putalpha(ImageChops.multiply(clipped.getchannel("A"), mask))
    return clipped


def main() -> None:
    base = make_base_icon()
    base.save(PNG_OUT)
    base.save(ICO_OUT, sizes=[(size, size) for size in SIZES])


if __name__ == "__main__":
    main()
