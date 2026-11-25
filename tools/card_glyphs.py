#!/usr/bin/env python3
# Makes the letters of the PageCard drawing from the website's own fonts, so a card shows the site's type in
# every app without any app loading a font: tools/card-glyphs.json holds each letter as an SVG path and the
# fonts' kerning, PageCard.sol holds the same data as six constants and the website reads the JSON.
# Gate G-47 checks that the constants in PageCard.sol are exactly the ones the JSON gives; that check needs
# only Python itself, while making the JSON needs fontTools.
#
#   python3 -m venv /tmp/glyphs && /tmp/glyphs/bin/pip install fonttools==4.60.2 brotli==1.2.1
#   /tmp/glyphs/bin/python tools/card_glyphs.py            # writes tools/card-glyphs.json and the PageCard constants
#   /tmp/glyphs/bin/python tools/card_glyphs.py --check    # exits 1 when the JSON or PageCard.sol would change
#
# Sources: Parkinsans at weight 800 for the name and Geist at weight 600 for the small text, both from
# tools/fonts and both under the SIL Open Font License 1.1, which reserves no font name for either.
# Each letter is scaled to a grid of whole units, turned upside down for SVG and rebuilt with cubic curves
# within one unit of the font's own quadratic ones, which needs fewer points. The name, drawn up to 150 pixels
# tall, has 200 units to the em, so a unit is at most 0.75 pixels; the small text, 28 pixels tall, has 100 units
# to the em, so a unit is 0.28 pixels.
import hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..')
JSON_PATH = os.path.join(HERE, 'card-glyphs.json')
SOL_PATH = os.path.join(HERE, '..', 'src', 'PageCard.sol')

# The order of the letters is part of the drawing: PageCard looks a letter up by this number.
# 0 to 25 a to z, 26 to 35 0 to 9, 36 the hyphen, 37 the dot, 38 the ellipsis, 39 the box for any other byte;
# the small text adds 40 the space and 41 to 53 the capitals its fixed words use.
COMMON = 'abcdefghijklmnopqrstuvwxyz0123456789-.…'
CAPITALS = 'ADEFGIJMNOSTU'
NOTDEF = '\0'
FACES = {
    'name': {'font': 'tools/fonts/parkinsans/parkinsans-600-800.latin.woff2', 'weight': 800,
             'units': 200, 'kernMin': 0, 'chars': COMMON + NOTDEF},
    # the small text keeps the kerning pairs it can show of at least 36 font units, a pixel at its size
    'text': {'font': 'tools/fonts/geist/geist-400-700.latin.woff2', 'weight': 600,
             'units': 100, 'kernMin': 36, 'chars': COMMON + NOTDEF + ' ' + CAPITALS},
}


def box(units):
    """Neither font draws its .notdef, so any other byte shows as a hollow box 0.7 em tall on the baseline, 0.46 em
    wide with sides of 0.08 em, in an advance of 0.6 em."""
    x, w, h, t = (round(f * units) for f in (0.07, 0.46, 0.7, 0.08))
    return f'M{x} 0v-{h}h{w}v{h}zm{t}-{t}h{w - 2 * t}v-{h - 2 * t}h-{w - 2 * t}z', round(0.6 * units)


def outline(glyph_set, name, upm, units):
    """The outline of a glyph as SVG path data on the grid, y down: an absolute first move, then relative commands,
    so a letter can be placed with a translate alone. Every point is rounded to the grid before any step is taken,
    so the steps never drift."""
    from fontTools.pens.basePen import BasePen
    from fontTools.pens.qu2cuPen import Qu2CuPen

    class Recorder(BasePen):
        def __init__(self):
            super().__init__(glyph_set)
            self.ops = []

        def _moveTo(self, p): self.ops.append(('M', [p]))
        def _lineTo(self, p): self.ops.append(('L', [p]))
        def _qCurveToOne(self, a, b): self.ops.append(('Q', [a, b]))
        def _curveToOne(self, a, b, c): self.ops.append(('C', [a, b, c]))
        def _closePath(self): self.ops.append(('Z', []))
        def _endPath(self): self.ops.append(('Z', []))

    scale = units / upm
    rec = Recorder()
    glyph_set[name].draw(Qu2CuPen(rec, max_err=1 / scale, all_cubic=False))

    def grid(p):
        return (round(p[0] * scale), round(-p[1] * scale))
    cmds, cur, start = [], None, None
    for op, pts in rec.ops:
        q = [grid(p) for p in pts]
        if op == 'M':
            cmds.append(('M', q[0]) if cur is None else ('m', (q[0][0] - cur[0], q[0][1] - cur[1])))
            cur = start = q[0]
        elif op == 'L':
            dx, dy = q[0][0] - cur[0], q[0][1] - cur[1]
            if dx == 0 and dy == 0:
                continue
            cmds.append(('h', (dx,)) if dy == 0 else ('v', (dy,)) if dx == 0 else ('l', (dx, dy)))
            cur = q[0]
        elif op == 'Q':
            a, b = q
            cmds.append(('q', (a[0] - cur[0], a[1] - cur[1], b[0] - cur[0], b[1] - cur[1])))
            cur = b
        elif op == 'C':
            a, b, c = q
            cmds.append(('c', (a[0] - cur[0], a[1] - cur[1], b[0] - cur[0], b[1] - cur[1], c[0] - cur[0], c[1] - cur[1])))
            cur = c
        elif op == 'Z':
            if cmds and cmds[-1][0] != 'z':
                cmds.append(('z', ()))
            cur = start
    out, last = '', None
    for cmd, vals in cmds:
        if cmd == 'z':
            out += 'z'
            last = 'z'
            continue
        for i, v in enumerate(vals):
            t = str(v)
            # a new command letter or a minus sign separates numbers; otherwise a space does
            out += (cmd + t) if (i == 0 and cmd != last) else (t if t.startswith('-') else ' ' + t)
        last = cmd
    return out


def kerning(font, glyph_names):
    """The x advance change of every pair of these glyphs in the font's kern feature, in font units, as a shaper
    applies it: within one lookup the first subtable that covers the pair decides, and the lookups add up."""
    gpos = font['GPOS'].table
    lookups = sorted({i for fr in gpos.FeatureList.FeatureRecord if fr.FeatureTag == 'kern'
                      for i in fr.Feature.LookupListIndex})
    pairs = {}
    for li in lookups:
        lookup = gpos.LookupList.Lookup[li]
        subtables = [st.ExtSubTable if lookup.LookupType == 9 else st for st in lookup.SubTable]
        for a in glyph_names:
            for b in glyph_names:
                for st in subtables:
                    if st.LookupType != 2 or a not in st.Coverage.glyphs:
                        continue
                    if st.Format == 1:
                        rec = next((r for r in st.PairSet[st.Coverage.glyphs.index(a)].PairValueRecord
                                    if r.SecondGlyph == b), None)
                        if rec is None:
                            continue  # a format 1 subtable without the pair lets the next one try
                        v = getattr(rec.Value1, 'XAdvance', 0) if rec.Value1 else 0
                    else:
                        c1 = st.ClassDef1.classDefs.get(a, 0)
                        c2 = st.ClassDef2.classDefs.get(b, 0)
                        rec = st.Class1Record[c1].Class2Record[c2]
                        v = getattr(rec.Value1, 'XAdvance', 0) if rec.Value1 else 0
                    if v:
                        pairs[(a, b)] = pairs.get((a, b), 0) + v
                    break
    return pairs


def text_pairs_used():
    """The pairs the small text can show: inside its fixed words, in a date, in an address and in a parent's
    label after its dot."""
    words = ['Until', 'Trial', 'Grace period', 'Expired', 'Invalid',
             'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
    used = {(a, b) for w in words for a, b in zip(w, w[1:])}
    label = 'abcdefghijklmnopqrstuvwxyz0123456789-'
    used |= {(a, b) for a in label + '.' for b in label + '…'}
    hexes = '0123456789abcdefx'
    used |= {(a, b) for a in hexes + '…' for b in hexes + '…'}
    return used


def face(key):
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    spec = FACES[key]
    path = os.path.join(REPO, spec['font'])
    raw = open(path, 'rb').read()
    font = instantiateVariableFont(TTFont(path), {'wght': spec['weight']})
    upm, units = font['head'].unitsPerEm, spec['units']
    glyph_set, cmap, hmtx = font.getGlyphSet(), font.getBestCmap(), font['hmtx']
    glyphs, names = [], {}
    for ch in spec['chars']:
        if ch == NOTDEF:
            d, advance = box(units)
            glyphs.append({'char': ch, 'advance': advance, 'd': d})
            continue
        name = cmap[ord(ch)]
        names[name] = ch
        glyphs.append({'char': ch, 'advance': round(hmtx[name][0] * units / upm),
                       'd': outline(glyph_set, name, upm, units) if ch != ' ' else ''})
    index = {ch: i for i, ch in enumerate(spec['chars'])}
    used = text_pairs_used() if key == 'text' else None
    pairs = []
    for (a, b), v in kerning(font, list(names)).items():
        ca, cb = names[a], names[b]
        if used is not None and (ca, cb) not in used:
            continue
        g = round(v * units / upm)
        if g and abs(v) >= spec['kernMin']:
            pairs.append([index[ca], index[cb], g])
    pairs.sort()
    return {
        'font': spec['font'], 'sha256': hashlib.sha256(raw).hexdigest(), 'weight': spec['weight'],
        'units': units, 'kernMin': spec['kernMin'], 'glyphs': glyphs, 'kern': pairs,
    }


def build():
    from fontTools import version
    return {'note': 'Made by tools/card_glyphs.py; do not edit by hand.', 'fonttools': version,
            'name': face('name'), 'text': face('text')}


# ---------------------------------------------------------------------------------------- the Solidity constants
def _label(ch):
    return {'\0': 'any other byte', ' ': 'space', '…': 'ellipsis', '-': 'hyphen', '.': 'dot'}.get(ch, ch)


def sol_constants(data):
    """The source text after `=` of the six constants of PageCard.sol, up to and with the semicolon: for each face
    its outlines one after another, one letter to a line, its index (for each letter the end of its outline in the
    outlines, two bytes, and its advance, one byte) and its kerning (for each pair the two letter numbers and the
    signed change, one byte each, ordered by pair)."""
    out = {}
    for key, upper in (('name', 'NAME'), ('text', 'TEXT')):
        f = data[key]
        lines, end, index = [], 0, ''
        for g in f['glyphs']:
            end += len(g['d'])
            assert end < 1 << 16 and 0 < g['advance'] < 256
            index += f'{end:04x}{g["advance"]:02x}'
            if g['d']:
                lines.append(f'        "{g["d"]}" // {_label(g["char"])}')
        out[f'{upper}_PATHS'] = '\n' + '\n'.join(lines) + '\n    ;'
        out[f'{upper}_INDEX'] = f'\n        hex"{index}";'
        kern = ''
        for a, b, v in f['kern']:
            assert -128 <= v < 128
            kern += f'{a:02x}{b:02x}{v & 0xff:02x}'
        out[f'{upper}_KERN'] = f'\n        hex"{kern}";'
    return out


def _sol_slot(name):
    return re.compile(r'(bytes private constant ' + name + r' =)([^;]*;)')


def sol_differs(data, source):
    """The names of the constants whose text in PageCard.sol is not the text the JSON gives."""
    bad = []
    for name, text in sol_constants(data).items():
        m = _sol_slot(name).search(source)
        if not m or m.group(2) != text:
            bad.append(name)
    return bad


def sol_write(data, source):
    for name, text in sol_constants(data).items():
        source, n = _sol_slot(name).subn(lambda m: m.group(1) + text, source)
        assert n == 1, name
    return source


def main():
    data = build()
    text = json.dumps(data, indent=1, ensure_ascii=False) + '\n'
    if '--check' in sys.argv:
        old = open(JSON_PATH, encoding='utf-8').read() if os.path.exists(JSON_PATH) else ''
        bad = [] if old == text else ['tools/card-glyphs.json']
        bad += sol_differs(data, open(SOL_PATH, encoding='utf-8').read())
        print('card glyphs:', 'match' if not bad else 'differ in ' + ', '.join(bad))
        sys.exit(1 if bad else 0)
    open(JSON_PATH, 'w', encoding='utf-8').write(text)
    sol = open(SOL_PATH, encoding='utf-8').read()
    open(SOL_PATH, 'w', encoding='utf-8').write(sol_write(data, sol))
    for k in ('name', 'text'):
        f = data[k]
        print(k, len(f['glyphs']), 'letters,', sum(len(g['d']) for g in f['glyphs']), 'bytes of outline,',
              len(f['kern']), 'kerning pairs')


if __name__ == '__main__':
    main()
