#!/usr/bin/env python3
"""Turns a terminal capture (text with ANSI SGR escapes, as printed by
`tmux capture-pane -e -p`) into a PNG of a terminal window.

    render.py capture.ans out.png [--title TITLE] [--cols N]

    render.py capture.ans out.png --font "Noto Sans Mono"

Needs chromium (headless) and JetBrains Mono (the Nerd Font build, whose
files are found by name) installed, or any installed font with --font.
"""

import argparse
import html
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image

# Catppuccin Mocha: the 16 terminal colors, then foreground and background.
PALETTE = [
    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
    "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
]
FG = "#cdd6f4"
BG = "#1e1e2e"
FONT_DIR = "/usr/share/fonts/TTF"
FONT_SIZE = 15
LINE_HEIGHT = 1.45
PAD_X, PAD_Y, BAR = 22, 18, 38


def xterm256(n):
    if n < 16:
        return PALETTE[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


class Style:
    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = self.bg = None
        self.bold = self.dim = self.italic = self.underline = False

    def apply(self, params):
        codes = [int(p) if p else 0 for p in params.split(";")] if params else [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                self.reset()
            elif c == 1:
                self.bold = True
            elif c == 2:
                self.dim = True
            elif c == 3:
                self.italic = True
            elif c == 4:
                self.underline = True
            elif c == 22:
                self.bold = self.dim = False
            elif c == 23:
                self.italic = False
            elif c == 24:
                self.underline = False
            elif 30 <= c <= 37:
                self.fg = PALETTE[c - 30]
            elif 90 <= c <= 97:
                self.fg = PALETTE[c - 90 + 8]
            elif 40 <= c <= 47:
                self.bg = PALETTE[c - 40]
            elif 100 <= c <= 107:
                self.bg = PALETTE[c - 100 + 8]
            elif c == 39:
                self.fg = None
            elif c == 49:
                self.bg = None
            elif c in (38, 48) and i + 1 < len(codes):
                if codes[i + 1] == 5 and i + 2 < len(codes):
                    color = xterm256(codes[i + 2])
                    i += 2
                elif codes[i + 1] == 2 and i + 4 < len(codes):
                    color = "#%02x%02x%02x" % tuple(codes[i + 2:i + 5])
                    i += 4
                else:
                    color = None
                if c == 38:
                    self.fg = color
                else:
                    self.bg = color
            i += 1

    def css(self):
        out = []
        if self.fg:
            out.append("color:" + self.fg)
        if self.bg:
            out.append("background:" + self.bg)
        if self.bold:
            out.append("font-weight:700")
        if self.dim:
            out.append("opacity:.6")
        if self.italic:
            out.append("font-style:italic")
        if self.underline:
            out.append("text-decoration:underline")
        return ";".join(out)


SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_ESC = re.compile(r"\x1b\[[0-9;?]*[A-Za-ln-z]|\x1b[()][A-Z0-9]|\x1b\][^\x07]*\x07")


def to_html(text):
    style = Style()
    lines = []
    for raw in text.rstrip("\n").split("\n"):
        raw = OTHER_ESC.sub("", raw)
        parts = []
        pos = 0
        for m in SGR.finditer(raw):
            if m.start() > pos:
                parts.append((style.css(), raw[pos:m.start()]))
            style.apply(m.group(1))
            pos = m.end()
        if pos < len(raw):
            parts.append((style.css(), raw[pos:]))
        line = "".join(
            '<span style="%s">%s</span>' % (css, html.escape(t)) if css else html.escape(t)
            for css, t in parts
        )
        lines.append(line or "&#8203;")
    return lines


def page(lines, title, cols, family=None):
    char_w = FONT_SIZE * 0.6
    width = int(cols * char_w + 2 * PAD_X)
    height = int(len(lines) * FONT_SIZE * LINE_HEIGHT + 2 * PAD_Y + BAR)
    margin = 28
    fonts = "".join(
        "@font-face{font-family:T;src:url('file://%s/JetBrainsMonoNerdFont-%s.ttf');font-weight:%s;font-style:%s}"
        % (FONT_DIR, name, weight, style)
        for name, weight, style in [
            ("Regular", 400, "normal"), ("Bold", 700, "normal"),
            ("Italic", 400, "italic"), ("BoldItalic", 700, "italic"),
        ]
    )
    stack = "T,monospace"
    if family:
        fonts, stack = "", '"%s",monospace' % family
    body = "".join('<div class="l">%s</div>' % l for l in lines)
    doc = """<!doctype html><meta charset="utf-8"><style>%s
html,body{margin:0;background:%%s}
.w{margin:%dpx;width:%dpx;border-radius:12px;background:%s;overflow:hidden;
   box-shadow:0 18px 40px rgba(0,0,0,.45),0 0 0 1px rgba(255,255,255,.07)}
.b{height:%dpx;display:flex;align-items:center;padding:0 16px;gap:8px;background:#181825;
   font:600 13px system-ui,sans-serif;color:#7f849c}
.d{width:12px;height:12px;border-radius:50%%}
.t{flex:1;text-align:center;margin-right:52px}
.s{padding:%dpx %dpx;font:%dpx/%s %s;color:%s;white-space:pre}
.l{height:%.2fpx}
</style><div class="w"><div class="b"><span class="d" style="background:#f38ba8"></span>
<span class="d" style="background:#f9e2af"></span><span class="d" style="background:#a6e3a1"></span>
<span class="t">%s</span></div><div class="s">%s</div></div>""" % (
        fonts, margin, width, BG, BAR, PAD_Y, PAD_X, FONT_SIZE, LINE_HEIGHT, stack, FG,
        FONT_SIZE * LINE_HEIGHT, html.escape(title), body,
    )
    return doc, width + 2 * margin, height + 2 * margin


def shoot(doc, background, w, h, tmp, name):
    src = os.path.join(tmp, name + ".html")
    png = os.path.join(tmp, name + ".png")
    with open(src, "w", encoding="utf-8") as f:
        f.write(doc.replace("%s", background, 1))
    subprocess.run(
        ["chromium", "--headless", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
         "--force-device-scale-factor=2", "--window-size=%d,%d" % (w, h),
         "--screenshot=" + png, "file://" + src],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return Image.open(png).convert("RGB")


def matte(on_white, on_black):
    """Recovers a transparent image from renders on white and on black:
    alpha = 1 - (white - black), color = black / alpha."""
    w, b = on_white.load(), on_black.load()
    out = Image.new("RGBA", on_white.size)
    o = out.load()
    for y in range(on_white.size[1]):
        for x in range(on_white.size[0]):
            pw, pb = w[x, y], b[x, y]
            a = 255 - max(0, min(255, round(sum(pw[i] - pb[i] for i in range(3)) / 3)))
            if a == 0:
                o[x, y] = (0, 0, 0, 0)
            else:
                o[x, y] = tuple(min(255, round(pb[i] * 255 / a)) for i in range(3)) + (a,)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("out")
    ap.add_argument("--title", default="")
    ap.add_argument("--cols", type=int, default=0)
    ap.add_argument("--font", default=None, help="an installed font family to use instead")
    args = ap.parse_args()
    text = open(args.capture, encoding="utf-8", errors="replace").read()
    text = re.sub(r"(\n[ \t]*)+$", "", text.rstrip("\n") + "\n")  # trailing blank lines
    lines = to_html(text)
    cols = args.cols or max(len(SGR.sub("", OTHER_ESC.sub("", l))) for l in text.split("\n"))
    doc, w, h = page(lines, args.title, cols, args.font)
    with tempfile.TemporaryDirectory() as tmp:
        white = shoot(doc, "#ffffff", w, h, tmp, "white")
        black = shoot(doc, "#000000", w, h, tmp, "black")
    matte(white, black).save(args.out, optimize=True)


if __name__ == "__main__":
    sys.exit(main())
