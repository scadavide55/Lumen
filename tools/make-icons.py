#!/usr/bin/env python3
"""Renders Tacet's app icons from the SVG prototypes.

Writes, from docs/assets/logo-prototypes:
  Resources/AppIcons/<id>.png   every icon you can pick in Settings, 1024 px, transparent outside the rounded square
  Resources/Tacet.iconset       the default icon (Seal, corona) at every size macOS asks for, with its own 16 and 32 px drawing
  Resources/Tacet.icns          the iconset compiled by iconutil
  docs/assets/icon.png, favicon.png   the site's icon and favicon

Needs macOS (Quick Look draws the SVGs) and Pillow. Run from anywhere: python3 tools/make-icons.py
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTO = os.path.join(ROOT, 'docs/assets/logo-prototypes')
OUT = os.path.join(ROOT, 'Resources/AppIcons')
DEFAULT = 'seal-corona'
# The icon Tacet had until 1.6.4, kept as a picture since it was never an SVG.
ECLIPSE = os.path.join(PROTO, 'eclipse-original.png')
# The icons offered in Settings and in setup, besides the eclipse. Keep in step with AppIcon.all in Sources/Core/AppIcon.swift.
FINALS = ['seal-corona', 'corona-gold', 'corona-t-bold', 'corona-t-gold', 'last-light-rim', 'half-moon-corona', 'half-moon-stop',
          'half-moon-t', 'half-moon-soft', 'half-seal-t', 'seal-night-t', 'seal-night-half', 'seal-night-gold', 't-gold-coin',
          't-gold-ocean', 't-gold-halfground']


def render_svg(svg, size, tmp):
    """Quick Look draws the SVG (filters included) on white; the square's corners are then cut back to transparent."""
    subprocess.run(['qlmanage', '-t', '-s', str(size), '-o', tmp, svg], capture_output=True, check=True)
    img = Image.open(os.path.join(tmp, os.path.basename(svg) + '.png')).convert('RGBA')
    if img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)
    return masked(img)


def masked(img):
    """Transparent outside the rounded square (100–924 of 1024, radius 184), antialiased, with the soft shadow macOS icons carry."""
    size = img.size[0]
    k = size / 1024
    big = 4
    m = Image.new('L', (size * big, size * big), 0)
    ImageDraw.Draw(m).rounded_rectangle([100 * k * big, 100 * k * big, 924 * k * big - 1, 924 * k * big - 1], radius=184 * k * big, fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    img.putalpha(m)
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    sm = Image.new('L', (size, size), 0)
    ImageDraw.Draw(sm).rounded_rectangle([100 * k, 112 * k, 924 * k, 936 * k], radius=184 * k, fill=int(255 * .28))
    shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(14 * k)))
    return Image.alpha_composite(shadow, img)


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        os.remove(os.path.join(OUT, f))
    with tempfile.TemporaryDirectory() as tmp:
        for name in FINALS:
            img = render_svg(os.path.join(PROTO, 'finals', name + '.svg'), 1024, tmp)
            img.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, name + '.png'), optimize=True)
        Image.open(ECLIPSE).convert('RGBA').resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, 'eclipse.png'), optimize=True)

        # Default icon set: big sizes from the full drawing, 16 and 32 px from the simplified one.
        iconset = os.path.join(ROOT, 'Resources/Tacet.iconset')
        full = render_svg(os.path.join(PROTO, 'finals', DEFAULT + '.svg'), 1024, tmp)
        small_svg = os.path.join(PROTO, 'finals', DEFAULT + '-small.svg')
        small = render_svg(small_svg, 256, tmp) if os.path.exists(small_svg) else full
        sizes = {'16x16': (16, small), '16x16@2x': (32, small), '32x32': (32, small), '32x32@2x': (64, full),
                 '128x128': (128, full), '128x128@2x': (256, full), '256x256': (256, full), '256x256@2x': (512, full),
                 '512x512': (512, full), '512x512@2x': (1024, full)}
        for label, (px, src) in sizes.items():
            src.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f'icon_{label}.png'), optimize=True)
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(ROOT, 'Resources/Tacet.icns')], check=True)

        # Site
        full.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, 'docs/assets/icon.png'), optimize=True)
        small.resize((64, 64), Image.LANCZOS).save(os.path.join(ROOT, 'docs/assets/favicon.png'), optimize=True)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print(f'{len(os.listdir(OUT))} icons in Resources/AppIcons, {total // 1024} KB; Tacet.icns {os.path.getsize(os.path.join(ROOT, "Resources/Tacet.icns")) // 1024} KB')


if __name__ == '__main__':
    sys.exit(main())
