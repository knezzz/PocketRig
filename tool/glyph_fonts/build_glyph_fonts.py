"""Builds the two tiny terminal glyph fonts in assets/fonts from Noto fonts (SIL OFL 1.1; see OFL-NotoGlyphs.txt).

  PocketRigGlyphs.ttf  braille U+2800-28FF (the spinners), and what coding agents draw with: Arrows U+2190-21FF, Misc Technical
                       U+2300-23FF (Claude's tool-result elbow ⎿, ⏵ ⏴ ⌫ ⎋), Dingbats U+2700-27BF (✻ ✔ ✗ ✓ ➜ ✢ ✳), ※ U+203B
                       and ⋯ U+22EF (the ellipses ⋮-⋱), Geometric Shapes U+25A0-25FF (○ ◐ ◦) and ⧉ U+29C9; from Noto Sans Symbols 2, then Noto Sans Math and Noto Sans Symbols for what it lacks
  PocketRigEmoji.ttf   U+2728 (sparkles), from Noto Emoji's monochrome outline

Each glyph is re-centred (and scaled when it is wider than its cell) in the JetBrains Mono cell: 600 units, or 1200 for the
two-column sparkles, so a terminal draws one glyph per cell. Run with fontTools installed:

  python3 tool/glyph_fonts/build_glyph_fonts.py NotoSansSymbols2-Regular.ttf NotoEmoji-Regular.ttf assets/fonts \\
      NotoSansMath-Regular.ttf NotoSansSymbols-Regular.ttf
"""
import sys


from fontTools import subset
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

CELL = 600


def subset_font(font, unicodes):
    opts = subset.Options()
    opts.layout_features = []
    opts.hinting = False
    opts.notdef_outline = True
    opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    opts.glyph_names = False
    s = subset.Subsetter(opts)
    s.populate(unicodes=unicodes)
    s.subset(font)
    return font


def fit(font, advance, scale_to=None, unit=1000):
    """Scales to [unit] per em, then centres every glyph in [advance] (shrinking to [scale_to] wide when wider)."""
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()
    up = font["head"].unitsPerEm
    glyf = font["glyf"]
    # Outlines first, composites decomposed, before any glyph is replaced: a composite reads its parts as they were.
    drawn = {}
    for name in set(cmap.values()) - {".notdef"}:
        rec = DecomposingRecordingPen(gs)
        gs[name].draw(rec)
        drawn[name] = rec
    for cp, name in cmap.items():
        if name == ".notdef":
            continue
        bp = BoundsPen(gs)
        drawn[name].replay(bp)
        b = bp.bounds
        k = unit / up
        if b is not None:
            w = (b[2] - b[0]) * k
            if scale_to and w > scale_to:
                k *= scale_to / w
            cx = (b[0] + b[2]) / 2 * k
            tx = advance / 2 - cx
        else:
            tx = 0
        pen = TTGlyphPen(None)
        drawn[name].replay(TransformPen(pen, (k, 0, 0, k, tx, 0)))
        g = pen.glyph()
        glyf[name] = g
        g.recalcBounds(glyf)
        # hmtx's left side bearing must equal the glyph's xMin, or renderers shift it.
        font["hmtx"][name] = (advance, getattr(g, "xMin", 0) if g.numberOfContours else 0)
    font["head"].unitsPerEm = unit
    return font


def jetbrains_metrics(font):
    """JetBrains Mono's vertical metrics, so a glyph from these fonts never makes a terminal line taller."""
    h, o = font["hhea"], font["OS/2"]
    h.ascent, h.descent, h.lineGap = 1020, -300, 0
    o.sTypoAscender, o.sTypoDescender, o.sTypoLineGap = 1020, -300, 0
    o.usWinAscent, o.usWinDescent = 1020, 300


def rename(font, family):
    for rec in font["name"].names:
        if rec.nameID in (1, 4, 16):
            rec.string = family
        elif rec.nameID == 6:
            rec.string = family.replace(" ", "") + "-Regular"


WANTED = (list(range(0x2800, 0x2900)) + list(range(0x2190, 0x2200)) + list(range(0x2300, 0x2400)) + list(range(0x2700, 0x27C0))
          + list(range(0x25A0, 0x2600)) + list(range(0x22EE, 0x22F2)) + [0x203B, 0x29C9])
# U+2728 (sparkles) is two cells wide and has its own font.
WANTED = [c for c in WANTED if c != 0x2728]


def reference_mark(font):
    """※ U+203B (the reference mark): no open font in this set has it, so it is drawn here: a cross with a dot on each side."""
    import math

    def clockwise(pts):
        area = sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(pts, pts[1:] + pts[:1]))
        return pts if area < 0 else pts[::-1]

    cx, cy, t = CELL / 2, 330, 28
    pen = TTGlyphPen(None)
    for sx in (1, -1):  # the two diagonals of the cross
        (x1, y1), (x2, y2) = (-120, -120 * sx), (120, 120 * sx)
        n = math.hypot(x2 - x1, y2 - y1)
        dx, dy = -(y2 - y1) / n * t, (x2 - x1) / n * t
        pts = [(cx + x1 + dx, cy + y1 + dy), (cx + x2 + dx, cy + y2 + dy), (cx + x2 - dx, cy + y2 - dy), (cx + x1 - dx, cy + y1 - dy)]
        c = clockwise([(round(x), round(y)) for x, y in pts])
        pen.moveTo(c[0])
        for q in c[1:]:
            pen.lineTo(q)
        pen.closePath()
    for ox, oy in ((0, 200), (0, -200), (200, 0), (-200, 0)):  # the dots
        c = clockwise([(round(cx + ox + 46 * math.cos(a * math.pi / 4 + math.pi / 8)), round(cy + oy + 46 * math.sin(a * math.pi / 4 + math.pi / 8))) for a in range(8)])
        pen.moveTo(c[0])
        for q in c[1:]:
            pen.lineTo(q)
        pen.closePath()
    g = pen.glyph()
    font["glyf"]["pr203B"] = g
    order = list(dict.fromkeys(list(font.getGlyphOrder()) + ["pr203B"]))
    font.setGlyphOrder(order)
    font["maxp"].numGlyphs = len(order)
    font["hmtx"]["pr203B"] = (CELL, min(x for x, _ in g.coordinates))  # lsb = xMin
    for t in font["cmap"].tables:
        if t.isUnicode():
            t.cmap[0x203B] = "pr203B"


def merge_into(base, part):
    """Copies [part]'s glyphs and cmap into [base] (fontTools.merge trips over the fonts' differing tables)."""
    # No glyph names in the file: otherwise the post table, read late, resets the glyph order to the old names.
    base["post"].formatType = 3.0
    order = list(base.getGlyphOrder())
    for cp, name in sorted(part.getBestCmap().items()):
        if name == ".notdef":
            continue
        new = "pr%04X" % cp
        base["glyf"][new] = part["glyf"][name]
        base["hmtx"][new] = part["hmtx"][name]
        order.append(new)
        for t in base["cmap"].tables:
            if t.isUnicode():
                t.cmap[cp] = new
    base.setGlyphOrder(order)
    base["maxp"].numGlyphs = len(order)


def main(symbols_path, emoji_path, out, math_path=None, symbols1_path=None):
    taken = set()
    sym = None
    for path in [symbols_path, math_path, symbols1_path]:
        if not path:
            continue
        f = TTFont(path)
        have = set(f.getBestCmap())
        mine = [c for c in WANTED if c in have and c not in taken]
        taken.update(mine)
        f = subset_font(f, mine)
        fit(f, CELL, scale_to=CELL * 0.92)
        for t in ("vhea", "vmtx", "GSUB", "GPOS", "GDEF", "MATH", "BASE", "JSTF", "kern"):  # a terminal reads none of them
            if t in f:
                del f[t]
        if sym is None:
            sym = f
        else:
            merge_into(sym, f)
    reference_mark(sym)
    taken.add(0x203B)
    jetbrains_metrics(sym)
    rename(sym, "PocketRig Glyphs")
    sym.save(f"{out}/PocketRigGlyphs.ttf")
    print("covered", len(taken), "of", len(WANTED), "missing", sorted(hex(c) for c in set(WANTED) - taken)[:40])

    emoji = TTFont(emoji_path)
    if "fvar" in emoji:
        emoji = instancer.instantiateVariableFont(emoji, {"wght": 400})
    emoji = subset_font(emoji, [0x2728])
    fit(emoji, CELL * 2, scale_to=CELL * 2 * 0.92)
    jetbrains_metrics(emoji)
    rename(emoji, "PocketRig Emoji")
    emoji.save(f"{out}/PocketRigEmoji.ttf")


if __name__ == "__main__":
    main(*sys.argv[1:6])
