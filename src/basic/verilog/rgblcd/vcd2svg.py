#!/usr/bin/env python3
"""
vcd2svg.py — Generate SVG + PDF timing diagrams from VCD simulation output.

Zero external dependencies — uses only Python 3 stdlib.

Usage:
    python3 vcd2svg.py <vcd_file> [options]

Options:
    --output-dir DIR    Write outputs to DIR (default: same dir as VCD file)
    --list              List all signals in VCD file and exit
    --views V1,V2,...   Comma-separated view names to generate (default: all)
    --svg-only          Skip PDF generation
"""

import sys
import os
import re
import zlib
import xml.etree.ElementTree as ET
from bisect import bisect_right

# =============================================================================
# VCD Parser
# =============================================================================

class VCDSignal:
    """A signal parsed from a VCD file."""
    __slots__ = ('var_type', 'width', 'code', 'name', 'scope', 'full_name',
                 'changes')

    def __init__(self, var_type, width, code, name, scope):
        self.var_type = var_type
        self.width = width
        self.code = code
        self.name = name
        self.scope = list(scope)
        self.full_name = '.'.join(scope + [name]) if scope else name
        self.changes = []  # [(time_ps, value_str), ...]


def parse_vcd(filename, max_time=None):
    """
    Parse a VCD file up to max_time (in VCD time units).
    Returns dict of {full_name: VCDSignal}.
    """
    signals_by_code = {}
    signals_by_name = {}
    scope_stack = []
    current_time = 0
    in_defs = True

    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if in_defs:
                if line.startswith('$timescale'):
                    pass  # we read the header separately if needed
                elif line.startswith('$scope'):
                    parts = line.split()
                    if len(parts) >= 3:
                        scope_stack.append(parts[2])
                elif line.startswith('$upscope'):
                    if scope_stack:
                        scope_stack.pop()
                elif line.startswith('$var'):
                    parts = line.split()
                    if len(parts) >= 5:
                        var_type = parts[1]
                        width = int(parts[2])
                        code = parts[3]
                        name = parts[4]
                        sig = VCDSignal(var_type, width, code, name,
                                        scope_stack)
                        signals_by_code.setdefault(code, []).append(sig)
                        signals_by_name[sig.full_name] = sig
                elif line.startswith('$enddefinitions'):
                    in_defs = False
            else:
                # Value change section
                if line.startswith('#'):
                    current_time = int(line[1:])
                    if max_time is not None and current_time > max_time:
                        break
                elif line.startswith('$'):
                    continue
                elif line[0] in '01xXzZ':
                    val = line[0]
                    code = line[1:]
                    for sig in signals_by_code.get(code, []):
                        sig.changes.append((current_time, val))
                elif line[0] in 'bB':
                    parts = line.split()
                    if len(parts) == 2:
                        val = parts[0][1:]  # strip 'b'/'B'
                        code = parts[1]
                        for sig in signals_by_code.get(code, []):
                            sig.changes.append((current_time, val))
                elif line[0] in 'rR':
                    parts = line.split()
                    if len(parts) == 2:
                        code = parts[1]
                        val = parts[0][1:]
                        for sig in signals_by_code.get(code, []):
                            sig.changes.append((current_time, val))

    return signals_by_name


def find_signal(signals, path):
    """
    Find a signal by path, with fallback suffix matching.
    Tries: exact match, then suffix match (e.g. "LCD_HSYNC" matches
    "test_lcd.uut.LCD_HSYNC").
    """
    if path in signals:
        return signals[path]
    # Suffix match
    for name, sig in signals.items():
        if name.endswith('.' + path) or name == path:
            return sig
    # Partial match on last component
    target = path.rsplit('.', 1)[-1]
    for name, sig in signals.items():
        if name.rsplit('.', 1)[-1] == target:
            return sig
    return None


def get_value_at(changes, time):
    """Get signal value at a given time via binary search."""
    if not changes:
        return 'x'
    # bisect for last change at or before 'time'
    idx = bisect_right(changes, (time, '~')) - 1  # '~' > any value char
    if idx >= 0:
        return changes[idx][1]
    return 'x'


# =============================================================================
# SVG Renderer
# =============================================================================

def hex_label(val_bin, width):
    """Format a binary-string VCD value as a hex label."""
    cleaned = val_bin.replace('x', '0').replace('X', '0') \
                     .replace('z', '0').replace('Z', '0')
    try:
        n = int(cleaned, 2)
        digits = (width + 3) // 4
        return f'{n:0{digits}X}h'
    except ValueError:
        return '?'


def dec_label(val_bin):
    """Format a binary-string VCD value as a decimal label."""
    cleaned = val_bin.replace('x', '0').replace('X', '0') \
                     .replace('z', '0').replace('Z', '0')
    try:
        return str(int(cleaned, 2))
    except ValueError:
        return '?'


def bit_y(val, y_top, y_bot):
    """Map a single-bit value to a y coordinate."""
    if val in ('1',):
        return y_top
    if val in ('0',):
        return y_bot
    return (y_top + y_bot) / 2


def format_time(ps_value, unit='auto'):
    """Format a time value (in ps) for axis labels."""
    if unit == 'auto':
        if ps_value >= 1_000_000_000:
            unit = 'ms'
        elif ps_value >= 1_000_000:
            unit = 'us'
        elif ps_value >= 1_000:
            unit = 'ns'
        else:
            unit = 'ps'

    if unit == 'ms':
        return f'{ps_value / 1e9:.2f}ms'
    if unit == 'us':
        return f'{ps_value / 1e6:.1f}us'
    if unit == 'ns':
        return f'{ps_value / 1e3:.0f}ns'
    return f'{ps_value}ps'


def format_time_axis(ps_value, unit, step):
    """Format a time value for axis labels with appropriate precision."""
    if unit == 'ms':
        # Decide decimals based on step size
        if step >= 100_000_000:
            return f'{ps_value / 1e9:.1f}ms'
        return f'{ps_value / 1e9:.2f}ms'
    if unit == 'us':
        if step >= 1_000_000:
            return f'{ps_value / 1e6:.0f}us'
        if step >= 100_000:
            return f'{ps_value / 1e6:.1f}us'
        if step >= 10_000:
            return f'{ps_value / 1e6:.2f}us'
        return f'{ps_value / 1e6:.3f}us'
    if unit == 'ns':
        if step >= 1_000:
            return f'{ps_value / 1e3:.0f}ns'
        return f'{ps_value / 1e3:.1f}ns'
    return f'{ps_value}ps'


def choose_time_step(t_range_ps, target_labels=12):
    """Choose a nice round time step for axis labels."""
    raw = t_range_ps / target_labels
    # Round to 1/2/5 * 10^n
    import math
    if raw <= 0:
        return 1
    exp = math.floor(math.log10(raw))
    mantissa = raw / (10 ** exp)
    if mantissa <= 1.5:
        nice = 1
    elif mantissa <= 3.5:
        nice = 2
    elif mantissa <= 7.5:
        nice = 5
    else:
        nice = 10
    return int(nice * (10 ** exp))


class SVGTimingDiagram:
    """Renders signal waveforms to SVG."""

    BG_COLOR = '#ffffff'
    GRID_COLOR = '#e8e8e8'
    GRID_MAJOR = '#d0d0d0'
    LABEL_COLOR = '#333333'
    TITLE_COLOR = '#111111'
    TIME_COLOR = '#888888'
    BUS_FILL = '#dde8f8'
    BUS_UNDEF_FILL = '#ffe8cc'

    def __init__(self, title='', label_width=140, row_height=40,
                 header_height=50):
        self.title = title
        self.label_width = label_width
        self.row_height = row_height
        self.header_height = header_height

    def render(self, signals_config, signals_data, t_start, t_end,
               output_file, width=1400):
        """
        Render timing diagram to SVG.

        signals_config: list of dicts:
            name:  display label
            path:  VCD signal path (fuzzy-matched)
            type:  'bit' or 'bus'
            color: stroke color
            fmt:   'hex' (default) or 'dec' for bus labels
        signals_data: dict from parse_vcd()
        t_start, t_end: time range in ps
        """
        right_margin = 20
        wave_w = width - self.label_width - right_margin
        n_rows = len(signals_config)
        total_h = self.header_height + n_rows * self.row_height + 20

        px_per_ps = wave_w / (t_end - t_start)

        svg = []
        svg.append(
            f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'width="{width}" height="{total_h}" '
            f'viewBox="0 0 {width} {total_h}" '
            f'style="font-family:monospace">'
        )
        svg.append(
            f'<rect width="{width}" height="{total_h}" fill="{self.BG_COLOR}"/>'
        )

        # Title
        if self.title:
            svg.append(
                f'<text x="{width // 2}" y="22" text-anchor="middle" '
                f'font-size="14" font-weight="bold" '
                f'fill="{self.TITLE_COLOR}">{esc(self.title)}</text>'
            )

        x0 = self.label_width  # waveform left edge

        # --- Time axis ---
        t_range = t_end - t_start
        step = choose_time_step(t_range)
        # Determine display unit from the first label
        sample_t = t_start + step
        if sample_t >= 1_000_000_000:
            time_unit = 'ms'
        elif sample_t >= 1_000_000:
            time_unit = 'us'
        elif sample_t >= 1_000:
            time_unit = 'ns'
        else:
            time_unit = 'ps'

        t = ((t_start // step) + 1) * step
        while t < t_end:
            x = x0 + (t - t_start) * px_per_ps
            # Grid line
            svg.append(
                f'<line x1="{x:.1f}" y1="{self.header_height}" '
                f'x2="{x:.1f}" y2="{total_h - 20}" '
                f'stroke="{self.GRID_COLOR}" stroke-width="0.5"/>'
            )
            # Label
            lbl = format_time_axis(t, time_unit, step)
            svg.append(
                f'<text x="{x:.1f}" y="{self.header_height - 6}" '
                f'text-anchor="middle" font-size="9" '
                f'fill="{self.TIME_COLOR}">{lbl}</text>'
            )
            t += step

        # --- Signal rows ---
        for row, cfg in enumerate(signals_config):
            y_base = self.header_height + row * self.row_height
            y_top = y_base + 6
            y_bot = y_base + self.row_height - 6
            y_mid = (y_top + y_bot) / 2
            color = cfg.get('color', '#22aa22')

            # Row separator
            svg.append(
                f'<line x1="{x0}" y1="{y_base}" '
                f'x2="{width - right_margin}" y2="{y_base}" '
                f'stroke="{self.GRID_COLOR}" stroke-width="0.5"/>'
            )

            # Label
            svg.append(
                f'<text x="{x0 - 6}" y="{y_mid + 4}" text-anchor="end" '
                f'font-size="11" fill="{self.LABEL_COLOR}">'
                f'{esc(cfg["name"])}</text>'
            )

            sig = find_signal(signals_data, cfg['path'])
            if sig is None:
                svg.append(
                    f'<text x="{x0 + 10}" y="{y_mid + 4}" font-size="9" '
                    f'fill="#cc0000">not found: {esc(cfg["path"])}</text>'
                )
                continue

            sig_type = cfg.get('type', 'bit')
            if sig_type == 'bit':
                self._draw_bit(svg, sig, t_start, t_end, x0, y_top, y_bot,
                               wave_w, px_per_ps, color)
            else:
                fmt = cfg.get('fmt', 'hex')
                self._draw_bus(svg, sig, t_start, t_end, x0, y_top, y_bot,
                               wave_w, px_per_ps, color, fmt)

        # Bottom border
        y_bottom = self.header_height + n_rows * self.row_height
        svg.append(
            f'<line x1="{x0}" y1="{y_bottom}" '
            f'x2="{width - right_margin}" y2="{y_bottom}" '
            f'stroke="{self.GRID_COLOR}" stroke-width="0.5"/>'
        )

        svg.append('</svg>')

        with open(output_file, 'w') as f:
            f.write('\n'.join(svg))

    # ----- single-bit waveform -----

    def _draw_bit(self, svg, sig, t0, t1, x0, y_top, y_bot,
                  wave_w, px_per_ps, color):
        val = get_value_at(sig.changes, t0)
        y_prev = bit_y(val, y_top, y_bot)
        x_end = x0 + wave_w

        path = [f'M {x0:.2f} {y_prev:.2f}']

        for t, v in sig.changes:
            if t < t0:
                continue
            if t > t1:
                break
            x = x0 + (t - t0) * px_per_ps
            new_y = bit_y(v, y_top, y_bot)
            path.append(f'L {x:.2f} {y_prev:.2f}')
            path.append(f'L {x:.2f} {new_y:.2f}')
            y_prev = new_y

        path.append(f'L {x_end:.2f} {y_prev:.2f}')

        svg.append(
            f'<path d="{" ".join(path)}" '
            f'fill="none" stroke="{color}" stroke-width="1.5"/>'
        )

    # ----- multi-bit bus waveform -----

    def _draw_bus(self, svg, sig, t0, t1, x0, y_top, y_bot,
                  wave_w, px_per_ps, color, fmt):
        y_mid = (y_top + y_bot) / 2
        x_end = x0 + wave_w
        min_label_px = 24  # minimum segment width to show a text label

        # Build transition list within [t0, t1]
        transitions = []
        init_val = get_value_at(sig.changes, t0)
        transitions.append((t0, init_val))

        for t, v in sig.changes:
            if t <= t0:
                continue
            if t > t1:
                break
            transitions.append((t, v))
        transitions.append((t1 + 1, None))  # sentinel

        for i in range(len(transitions) - 1):
            t_a, val = transitions[i]
            t_b, _ = transitions[i + 1]
            xa = x0 + (t_a - t0) * px_per_ps
            xb = x0 + (t_b - t0) * px_per_ps
            xb = min(xb, x_end)
            seg_w = xb - xa
            if seg_w < 0.5:
                continue

            dw = min(4, seg_w / 2)  # diamond taper width

            has_x = val is not None and ('x' in val or 'X' in val)
            fill = self.BUS_UNDEF_FILL if has_x else self.BUS_FILL

            pts = (f'{xa:.1f},{y_mid:.1f} '
                   f'{xa + dw:.1f},{y_top:.1f} '
                   f'{xb - dw:.1f},{y_top:.1f} '
                   f'{xb:.1f},{y_mid:.1f} '
                   f'{xb - dw:.1f},{y_bot:.1f} '
                   f'{xa + dw:.1f},{y_bot:.1f}')

            svg.append(
                f'<polygon points="{pts}" '
                f'fill="{fill}" stroke="{color}" stroke-width="1"/>'
            )

            # Label
            if seg_w > min_label_px and val is not None:
                if fmt == 'dec':
                    lbl = dec_label(val)
                else:
                    lbl = hex_label(val, sig.width)
                svg.append(
                    f'<text x="{(xa + xb) / 2:.1f}" y="{y_mid + 4:.1f}" '
                    f'text-anchor="middle" font-size="9" '
                    f'fill="#335">{esc(lbl)}</text>'
                )


def esc(text):
    """Escape text for SVG/XML."""
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


# =============================================================================
# PDF Writer — pure Python, zero dependencies
# =============================================================================

def _pdf_escape(s):
    """Escape a string for a PDF text object."""
    # Replace non-latin-1 chars (e.g. em-dash U+2014) with ASCII equivalents
    s = s.replace('\u2014', '--').replace('\u2013', '-')
    s = s.replace('\u2018', "'").replace('\u2019', "'")
    s = s.replace('\u201c', '"').replace('\u201d', '"')
    return s.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')


def _hex_to_rgb01(h):
    """Convert '#rrggbb' to (r, g, b) floats in 0..1."""
    h = h.lstrip('#')
    if len(h) == 3:
        h = h[0]*2 + h[1]*2 + h[2]*2
    return (int(h[0:2], 16) / 255,
            int(h[2:4], 16) / 255,
            int(h[4:6], 16) / 255)


class PDFWriter:
    """
    Minimal PDF 1.4 writer.  Supports pages with stream content only.
    Uses Courier (built-in Type 1, monospace — matches SVG font-family).
    """

    def __init__(self):
        self._objects = []   # list of bytes objects (PDF indirect objects)
        self._pages = []     # list of (page_obj_id, width_pt, height_pt)

    # ---- low-level helpers ----

    def _add_obj(self, data):
        """Add an indirect object; returns its 1-based id."""
        self._objects.append(data)
        # IDs 1..4 are reserved for catalog/pages/fonts, so offset by 4
        return len(self._objects) + 4

    # ---- public API ----

    def add_page(self, stream, width_pt, height_pt):
        """
        Add a page.  *stream* is an uncompressed PDF content stream (str).
        """
        # Encode to latin-1, replacing non-latin-1 chars (e.g. em-dash)
        # with a safe ASCII substitute.
        raw = stream.encode('latin-1', errors='replace')
        compressed = zlib.compress(raw)
        stream_id = self._add_obj(
            b'<< /Length ' + str(len(compressed)).encode() +
            b' /Filter /FlateDecode >>\nstream\n' +
            compressed + b'\nendstream'
        )
        page_id = self._add_obj(
            f'<< /Type /Page /Parent 2 0 R '
            f'/MediaBox [0 0 {width_pt:.2f} {height_pt:.2f}] '
            f'/Contents {stream_id} 0 R '
            f'/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >>'
            .encode()
        )
        self._pages.append((page_id, width_pt, height_pt))

    def write(self, filename):
        """Write the assembled PDF to *filename*."""
        # Object slots 1..4 are reserved:
        #   1=Catalog, 2=Pages, 3=Font(Courier), 4=Font(Courier-Bold)
        catalog = b'<< /Type /Catalog /Pages 2 0 R >>'
        kids = ' '.join(f'{pid} 0 R' for pid, _, _ in self._pages)
        pages = (f'<< /Type /Pages /Kids [{kids}] '
                 f'/Count {len(self._pages)} >>').encode()
        font_regular = b'<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>'
        font_bold = (b'<< /Type /Font /Subtype /Type1 '
                     b'/BaseFont /Courier-Bold >>')

        all_objs = [catalog, pages, font_regular, font_bold] + self._objects

        buf = b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'
        offsets = []
        for i, obj in enumerate(all_objs):
            offsets.append(len(buf))
            buf += f'{i+1} 0 obj\n'.encode()
            buf += obj + b'\nendobj\n'

        xref_offset = len(buf)
        buf += f'xref\n0 {len(all_objs)+1}\n'.encode()
        buf += b'0000000000 65535 f \n'
        for off in offsets:
            buf += f'{off:010d} 00000 n \n'.encode()
        buf += (f'trailer\n<< /Size {len(all_objs)+1} /Root 1 0 R >>\n'
                f'startxref\n{xref_offset}\n%%EOF\n').encode()

        with open(filename, 'wb') as f:
            f.write(buf)


def svg_to_pdf(svg_path, pdf_path):
    """
    Convert one of our generated SVGs to a single-page PDF.

    Only handles the SVG elements emitted by SVGTimingDiagram:
    rect, line, text, path (M/L), polygon.
    """
    tree = ET.parse(svg_path)
    root = tree.getroot()

    w = float(root.get('width', '1400'))
    h = float(root.get('height', '400'))
    # PDF uses points; our SVG pixels map 1:1 to PDF points.
    # PDF y-axis is bottom-up, so we flip: pdf_y = h - svg_y

    # Scale factor for Courier glyph widths (approximate).
    # Courier at size S has glyph width = 0.6 * S.
    COURIER_WIDTH_FACTOR = 0.6

    ops = []  # PDF content stream operations

    def flip(y):
        return h - y

    def set_stroke(color, width=1):
        r, g, b = _hex_to_rgb01(color)
        ops.append(f'{r:.3f} {g:.3f} {b:.3f} RG')
        ops.append(f'{width} w')

    def set_fill(color):
        r, g, b = _hex_to_rgb01(color)
        ops.append(f'{r:.3f} {g:.3f} {b:.3f} rg')

    for elem in root.iter():
        tag = elem.tag.split('}')[-1]  # strip namespace

        if tag == 'rect':
            rx = float(elem.get('x', '0'))
            ry = float(elem.get('y', '0'))
            rw = float(elem.get('width', '0'))
            rh = float(elem.get('height', '0'))
            fill = elem.get('fill', '#ffffff')
            set_fill(fill)
            ops.append(f'{rx:.2f} {flip(ry + rh):.2f} '
                       f'{rw:.2f} {rh:.2f} re f')

        elif tag == 'line':
            x1 = float(elem.get('x1', '0'))
            y1 = float(elem.get('y1', '0'))
            x2 = float(elem.get('x2', '0'))
            y2 = float(elem.get('y2', '0'))
            stroke = elem.get('stroke', '#000000')
            sw = float(elem.get('stroke-width', '1'))
            set_stroke(stroke, sw)
            ops.append(f'{x1:.2f} {flip(y1):.2f} m '
                       f'{x2:.2f} {flip(y2):.2f} l S')

        elif tag == 'path':
            d = elem.get('d', '')
            stroke = elem.get('stroke', '#000000')
            sw = float(elem.get('stroke-width', '1'))
            set_stroke(stroke, sw)
            # Parse M/L commands (the only ones we emit)
            tokens = d.replace(',', ' ').split()
            i = 0
            while i < len(tokens):
                cmd = tokens[i]
                if cmd in ('M', 'm'):
                    x, y = float(tokens[i+1]), float(tokens[i+2])
                    ops.append(f'{x:.2f} {flip(y):.2f} m')
                    i += 3
                elif cmd in ('L', 'l'):
                    x, y = float(tokens[i+1]), float(tokens[i+2])
                    ops.append(f'{x:.2f} {flip(y):.2f} l')
                    i += 3
                else:
                    # Might be implicit L coords
                    try:
                        x, y = float(tokens[i]), float(tokens[i+1])
                        ops.append(f'{x:.2f} {flip(y):.2f} l')
                        i += 2
                    except (ValueError, IndexError):
                        i += 1
            ops.append('S')  # stroke the path

        elif tag == 'polygon':
            pts_str = elem.get('points', '')
            fill = elem.get('fill', '#ffffff')
            stroke = elem.get('stroke', '#000000')
            sw = float(elem.get('stroke-width', '1'))
            coords = pts_str.replace(',', ' ').split()
            if len(coords) >= 4:
                set_fill(fill)
                set_stroke(stroke, sw)
                x0, y0 = float(coords[0]), float(coords[1])
                ops.append(f'{x0:.2f} {flip(y0):.2f} m')
                for j in range(2, len(coords), 2):
                    xp, yp = float(coords[j]), float(coords[j+1])
                    ops.append(f'{xp:.2f} {flip(yp):.2f} l')
                ops.append('b')  # close, fill and stroke

        elif tag == 'text':
            tx = float(elem.get('x', '0'))
            ty = float(elem.get('y', '0'))
            anchor = elem.get('text-anchor', 'start')
            fill = elem.get('fill', '#000000')
            fsize = float(elem.get('font-size', '11'))
            bold = 'bold' in elem.get('font-weight', '')
            text = (elem.text or '').strip()
            if not text:
                continue

            font_tag = '/F2' if bold else '/F1'
            set_fill(fill)
            # Adjust x for text-anchor
            text_w = len(text) * COURIER_WIDTH_FACTOR * fsize
            if anchor == 'middle':
                tx -= text_w / 2
            elif anchor == 'end':
                tx -= text_w

            # PDF text baseline: SVG y is roughly at the baseline already;
            # nudge down slightly since PDF Td is baseline-relative.
            ops.append('BT')
            ops.append(f'{font_tag} {fsize:.1f} Tf')
            ops.append(f'{tx:.2f} {flip(ty):.2f} Td')
            ops.append(f'({_pdf_escape(text)}) Tj')
            ops.append('ET')

    pdf = PDFWriter()
    pdf.add_page('\n'.join(ops), w, h)
    pdf.write(pdf_path)


# =============================================================================
# View definitions — customise these for your design
# =============================================================================
#
# Time values are in picoseconds (matching the VCD timescale 1ps).
# Clock period = 10 000 ps  (the testbench uses `always #5 pclk = ~pclk`
# with `timescale 1ns/1ps`).
#
# Timing (in clock cycles from frame start):
#   1 line  = xmax+1        = 526 clocks   = 5 260 000 ps
#   1 frame = ymax*526 + 1  = 149 911 clks = 1 499 110 000 ps
#   DE active: x ∈ [43..523], y ∈ [12..283]
#   First active line: clock 12*526+43 = 6355

CLK_PS       = 10_000           # one clock period in ps
LINE_CLKS    = 526              # clocks per line (xmax+1)
LINE_PS      = LINE_CLKS * CLK_PS
FRAME_CLKS   = 149_911          # clocks per frame
FRAME_PS     = FRAME_CLKS * CLK_PS
DE_X_START   = 43               # first x with DE=1
DE_Y_START   = 12               # first y with DE=1
FIRST_DE_CLK = DE_Y_START * LINE_CLKS + DE_X_START  # 6355


def auto_detect_views(signals):
    """
    Find the first DE rising edge in the VCD data and derive time windows
    for the standard views, anchored to the actual simulation timeline.
    Returns a list of view dicts with resolved t_start / t_end.
    """
    de_sig = find_signal(signals, 'test_lcd.LCD_DE')
    if de_sig is None:
        print('  WARNING: LCD_DE not found — using fallback time windows')
        return _fallback_views()

    # Find first 0→1 transition of DE
    t_first_de = None
    prev = '0'
    for t, v in de_sig.changes:
        if prev == '0' and v == '1':
            t_first_de = t
            break
        prev = v

    if t_first_de is None:
        print('  WARNING: DE never goes high — using fallback time windows')
        return _fallback_views()

    # DE first goes high at clock FIRST_DE_CLK within a frame. Work backwards
    # to find where this frame started (x=0, y=0).
    t_frame_start = t_first_de - FIRST_DE_CLK * CLK_PS

    # Find the first time LCD_G changes to a non-zero value (stripe boundary)
    g_sig = find_signal(signals, 'test_lcd.LCD_G')
    t_first_g = t_first_de + 20 * LINE_PS  # fallback
    if g_sig:
        for t, v in g_sig.changes:
            cleaned = v.replace('x', '0').replace('X', '0')
            if t > t_first_de and cleaned != '0' and int(cleaned, 2) != 0:
                t_first_g = t
                break

    print(f'  Auto-detected: first DE rise at {format_time(t_first_de)}, '
          f'frame start at {format_time(t_frame_start)}')

    margin = 2 * LINE_PS  # small margin before/after

    return [
        {
            'name': 'sync_timing_2lines',
            'title': 'Horizontal Sync Timing — First 2 Scan Lines',
            'signals': [
                {'name': 'HSYNC',   'path': 'test_lcd.LCD_HSYNC',
                 'type': 'bit', 'color': '#2266cc'},
                {'name': 'VSYNC',   'path': 'test_lcd.LCD_VSYNC',
                 'type': 'bit', 'color': '#cc2222'},
                {'name': 'DE',      'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
                {'name': 'x[15:0]', 'path': 'test_lcd.dut_x',
                 'type': 'bus', 'color': '#666666', 'fmt': 'dec'},
                {'name': 'y[15:0]', 'path': 'test_lcd.dut_y',
                 'type': 'bus', 'color': '#666666', 'fmt': 'dec'},
            ],
            't_start': t_frame_start,
            't_end':   t_frame_start + 2 * LINE_PS + margin,
            'width':   1800,
        },
        {
            'name': 'frame_overview',
            'title': 'Full Frame — VSYNC / HSYNC / DE',
            'signals': [
                {'name': 'VSYNC', 'path': 'test_lcd.LCD_VSYNC',
                 'type': 'bit', 'color': '#cc2222'},
                {'name': 'HSYNC', 'path': 'test_lcd.LCD_HSYNC',
                 'type': 'bit', 'color': '#2266cc'},
                {'name': 'DE',    'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
            ],
            't_start': t_frame_start,
            't_end':   t_frame_start + FRAME_PS + margin,
            'width':   1800,
        },
        {
            'name': 'active_lines',
            'title': 'Active Video — DE and RGB over 10 Scan Lines',
            'signals': [
                {'name': 'HSYNC',  'path': 'test_lcd.LCD_HSYNC',
                 'type': 'bit', 'color': '#2266cc'},
                {'name': 'DE',     'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
                {'name': 'R[4:0]', 'path': 'test_lcd.LCD_R',
                 'type': 'bus', 'color': '#cc3333'},
                {'name': 'G[5:0]', 'path': 'test_lcd.LCD_G',
                 'type': 'bus', 'color': '#33aa33'},
                {'name': 'B[4:0]', 'path': 'test_lcd.LCD_B',
                 'type': 'bus', 'color': '#3333cc'},
            ],
            # Show 10 active lines (py=0..9, covering stripes 0-2)
            't_start': t_first_de - 1 * LINE_PS,
            't_end':   t_first_de + 11 * LINE_PS,
            'width':   1800,
        },
        {
            'name': 'pixel_detail',
            'title': 'Pixel Detail — RGB Values at Stripe Boundary',
            'signals': [
                {'name': 'DE',     'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
                {'name': 'R[4:0]', 'path': 'test_lcd.LCD_R',
                 'type': 'bus', 'color': '#cc3333'},
                {'name': 'G[5:0]', 'path': 'test_lcd.LCD_G',
                 'type': 'bus', 'color': '#33aa33'},
                {'name': 'B[4:0]', 'path': 'test_lcd.LCD_B',
                 'type': 'bus', 'color': '#3333cc'},
                {'name': 'x[15:0]','path': 'test_lcd.dut_x',
                 'type': 'bus', 'color': '#666666', 'fmt': 'dec'},
            ],
            # Zoom into ~60 clocks around the first G transition (stripe
            # boundary), where all three RGB channels have interesting values.
            't_start': t_first_g - 30 * CLK_PS,
            't_end':   t_first_g + 30 * CLK_PS,
            'width':   1800,
        },
    ]


def _fallback_views():
    """Static fallback when auto-detection fails."""
    return [
        {
            'name': 'sync_timing_2lines',
            'title': 'Horizontal Sync Timing — First 2 Scan Lines',
            'signals': [
                {'name': 'HSYNC',   'path': 'test_lcd.LCD_HSYNC',
                 'type': 'bit', 'color': '#2266cc'},
                {'name': 'VSYNC',   'path': 'test_lcd.LCD_VSYNC',
                 'type': 'bit', 'color': '#cc2222'},
                {'name': 'DE',      'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
            ],
            't_start': 0,
            't_end':   12_000_000,
            'width':   1800,
        },
        {
            'name': 'frame_overview',
            'title': 'Full Frame — VSYNC / HSYNC / DE',
            'signals': [
                {'name': 'VSYNC', 'path': 'test_lcd.LCD_VSYNC',
                 'type': 'bit', 'color': '#cc2222'},
                {'name': 'HSYNC', 'path': 'test_lcd.LCD_HSYNC',
                 'type': 'bit', 'color': '#2266cc'},
                {'name': 'DE',    'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
            ],
            't_start': 0,
            't_end':   1_550_000_000,
            'width':   1800,
        },
        {
            'name': 'active_lines',
            'title': 'Active Video — DE and RGB',
            'signals': [
                {'name': 'DE',     'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
                {'name': 'R[4:0]', 'path': 'test_lcd.LCD_R',
                 'type': 'bus', 'color': '#cc3333'},
                {'name': 'G[5:0]', 'path': 'test_lcd.LCD_G',
                 'type': 'bus', 'color': '#33aa33'},
                {'name': 'B[4:0]', 'path': 'test_lcd.LCD_B',
                 'type': 'bus', 'color': '#3333cc'},
            ],
            't_start': 62_000_000,
            't_end':   130_000_000,
            'width':   1800,
        },
        {
            'name': 'pixel_detail',
            'title': 'Pixel Detail — RGB Values',
            'signals': [
                {'name': 'DE',     'path': 'test_lcd.LCD_DE',
                 'type': 'bit', 'color': '#22aa22'},
                {'name': 'R[4:0]', 'path': 'test_lcd.LCD_R',
                 'type': 'bus', 'color': '#cc3333'},
                {'name': 'G[5:0]', 'path': 'test_lcd.LCD_G',
                 'type': 'bus', 'color': '#33aa33'},
                {'name': 'B[4:0]', 'path': 'test_lcd.LCD_B',
                 'type': 'bus', 'color': '#3333cc'},
            ],
            't_start': 90_000_000,
            't_end':   90_600_000,
            'width':   1800,
        },
    ]


# =============================================================================
# CLI
# =============================================================================

def main():
    if len(sys.argv) < 2 or '--help' in sys.argv or '-h' in sys.argv:
        print(__doc__.strip())
        sys.exit(0)

    vcd_file = sys.argv[1]
    output_dir = os.path.dirname(os.path.abspath(vcd_file)) or '.'

    if '--output-dir' in sys.argv:
        idx = sys.argv.index('--output-dir')
        if idx + 1 < len(sys.argv):
            output_dir = sys.argv[idx + 1]

    os.makedirs(output_dir, exist_ok=True)

    # Determine max time needed — for auto-detect we need at least enough
    # data for the first DE activation.  Parse up to 8 frames worth, which
    # is more than the test runs.
    max_time = 8 * FRAME_PS

    print(f'Parsing {vcd_file} (up to {format_time(max_time)})...')
    signals = parse_vcd(vcd_file, max_time=max_time)
    print(f'  {len(signals)} signals loaded')

    if '--list' in sys.argv:
        for name in sorted(signals.keys()):
            s = signals[name]
            print(f'  {name}  ({s.width}-bit, {len(s.changes)} changes)')
        return

    views = auto_detect_views(signals)

    selected = None
    if '--views' in sys.argv:
        idx = sys.argv.index('--views')
        if idx + 1 < len(sys.argv):
            selected = set(sys.argv[idx + 1].split(','))
    if selected:
        views = [v for v in views if v['name'] in selected]

    renderer = SVGTimingDiagram()
    svg_only = '--svg-only' in sys.argv
    svg_files = []

    for view in views:
        out = os.path.join(output_dir, f'{view["name"]}.svg')
        renderer.title = view['title']
        renderer.render(
            signals_config=view['signals'],
            signals_data=signals,
            t_start=view['t_start'],
            t_end=view['t_end'],
            output_file=out,
            width=view.get('width', 1400),
        )
        print(f'  -> {out}')
        svg_files.append(out)

    if not svg_only:
        for svg_path in svg_files:
            pdf_path = svg_path.rsplit('.', 1)[0] + '.pdf'
            svg_to_pdf(svg_path, pdf_path)
            print(f'  -> {pdf_path}')

    print('Done.')


if __name__ == '__main__':
    main()
