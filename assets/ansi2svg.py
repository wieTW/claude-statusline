#!/usr/bin/env python3
"""ANSI (truecolor SGR) terminal output -> SVG screenshot.

Reads lines on stdin. A line starting with "@@" is a dim caption attached
above the NEXT content line. Emits a dark terminal-window SVG on stdout.
Only the SGR subset the statusline emits is handled: 0, 1, 38;2;r;g;b, 48;2;r;g;b.

Usage: ansi2svg.py [--title TEXT] [--pad-cols N] < frames.ansi > out.svg
"""
import sys, re, argparse
from html import escape

SGR = re.compile(r'\x1b\[([0-9;]*)m')

FONT = '"SF Mono","Cascadia Mono",Menlo,Consolas,"DejaVu Sans Mono",monospace'
FS, CW, CH = 14, 8.43, 22          # font size, cell width, line height
PAD_X, PAD_Y = 20, 14              # inner padding
BAR_H = 36                         # window title bar
BG, BORDER, DEFAULT_FG, CAPTION_FG = '#16161e', '#2f334d', '#a9b1d6', '#565f89'
CAPTION_H = 20


def parse_ansi(line):
    """-> list of (char, fg, bg, bold) cells."""
    cells, fg, bg, bold, pos = [], None, None, False, 0
    for m in SGR.finditer(line):
        for ch in line[pos:m.start()]:
            cells.append((ch, fg, bg, bold))
        pos = m.end()
        p = [int(x or 0) for x in m.group(1).split(';')] or [0]
        i = 0
        while i < len(p):
            if p[i] == 0:
                fg, bg, bold = None, None, False
            elif p[i] == 1:
                bold = True
            elif p[i] in (38, 48) and i + 4 < len(p) and p[i + 1] == 2:
                col = '#%02x%02x%02x' % (p[i + 2], p[i + 3], p[i + 4])
                if p[i] == 38:
                    fg = col
                else:
                    bg = col
                i += 4
            i += 1
    for ch in line[pos:]:
        cells.append((ch, fg, bg, bold))
    return cells


def runs(cells, key):
    """Group consecutive cells by key(cell) -> (start_col, text, keyval)."""
    out, start, cur = [], 0, None
    for i, c in enumerate(cells):
        k = key(c)
        if k != cur:
            if cur is not None:
                out.append((start, cells[start:i], cur))
            start, cur = i, k
    if cells and cur is not None:
        out.append((start, cells[start:], cur))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--title', default='')
    ap.add_argument('--pad-cols', type=int, default=0,
                    help='minimum width in columns (pads narrow frames)')
    a = ap.parse_args()

    raw = sys.stdin.read().rstrip('\n').split('\n')
    entries = []                       # (caption|None, cells)
    caption = None
    for line in raw:
        if line.startswith('@@'):
            caption = line[2:].strip()
        elif line.strip('\x1b[0m \t') or line.strip():
            entries.append((caption, parse_ansi(line)))
            caption = None

    ncols = max([len(c) for _, c in entries] + [a.pad_cols, 40])
    width = round(ncols * CW + 2 * PAD_X)
    y = BAR_H + PAD_Y
    body = []
    for cap, cells in entries:
        if cap is not None:
            y += CAPTION_H
            body.append(f'<text x="{PAD_X}" y="{y - 6}" fill="{CAPTION_FG}" '
                        f'font-family={FONT!r} font-size="11">{escape(cap)}</text>')
        # background runs (the ctx gradient bar)
        for col, run, bg in runs(cells, lambda c: c[2]):
            if bg:
                body.append(f'<rect x="{PAD_X + col * CW:.1f}" y="{y}" '
                            f'width="{len(run) * CW:.1f}" height="{CH}" fill="{bg}"/>')
        # text runs
        for col, run, (fg, bold) in runs(cells, lambda c: (c[1], c[3])):
            text = ''.join(ch for ch, *_ in run)
            if not text.strip():
                continue
            lead = len(text) - len(text.lstrip())
            text = text.strip()
            x = PAD_X + (col + lead) * CW
            w = len(text) * CW
            attr = f' font-weight="bold"' if bold else ''
            body.append(f'<text x="{x:.1f}" y="{y + CH - 6}" fill="{fg or DEFAULT_FG}"'
                        f'{attr} font-family={FONT!r} font-size="{FS}" xml:space="preserve" '
                        f'textLength="{w:.1f}" lengthAdjust="spacingAndGlyphs">{escape(text)}</text>')
        y += CH + 6
    height = y + PAD_Y

    dots = ''.join(f'<circle cx="{22 + i * 22}" cy="{BAR_H / 2}" r="6.5" fill="{c}"/>'
                   for i, c in enumerate(('#ff5f57', '#febc2e', '#28c840')))
    title = (f'<text x="{width / 2}" y="{BAR_H / 2 + 4}" fill="{CAPTION_FG}" text-anchor="middle" '
             f'font-family={FONT!r} font-size="12">{escape(a.title)}</text>' if a.title else '')
    print(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img">
<rect width="{width}" height="{height}" rx="10" fill="{BG}" stroke="{BORDER}"/>
{dots}{title}
{chr(10).join(body)}
</svg>''')


if __name__ == '__main__':
    main()
