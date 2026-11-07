#!/usr/bin/env python3
"""Render selected digital VCD signals without inventing samples.

Python 3.9+, standard library only. Not a protocol checker or a signoff tool.
Real/string/event/EVCD records are rejected rather than misinterpreted.
Changes to one signal at one timestamp are displayed at their final value;
the metadata counts these collapses. Use a simulator for delta-cycle analysis.
"""
import argparse
import bisect
import fnmatch
import hashlib
import html
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Signal:
    name: str
    code: str
    width: int
    kind: str
    bit_range: str = ""


@dataclass
class Trace:
    timescale: str
    signals: dict
    events: dict
    last_tick: int
    same_tick_collapses: int


def tokens(path):
    with Path(path).open(encoding="ascii", errors="strict") as stream:
        for line in stream:
            yield from line.split()


def parse_vcd(path, max_events=2_000_000):
    it = iter(tokens(path))
    scope, signals, events, widths = [], {}, {}, {}
    timescale, header, tick, count, collapsed = None, True, 0, 0, 0
    dump_block = False

    def block():
        values = []
        for value in it:
            if value == "$end":
                return values
            values.append(value)
        raise ValueError("Truncated VCD directive: missing $end")

    for token in it:
        if token in ("$comment", "$date", "$version"):
            block()
        elif token == "$timescale":
            if not header:
                raise ValueError("Timescale after enddefinitions")
            raw = "".join(block())
            if not re.fullmatch(r"(?:1|10|100)(?:s|ms|us|ns|ps|fs)", raw):
                raise ValueError("Unsupported or missing VCD timescale: " + raw)
            timescale = raw
        elif token == "$scope":
            parts = block()
            if not header or len(parts) != 2:
                raise ValueError("Malformed VCD scope")
            scope.append(parts[1])
        elif token == "$upscope":
            if block() or not header or not scope:
                raise ValueError("Unbalanced VCD scope")
            scope.pop()
        elif token == "$var":
            parts = block()
            if not header or len(parts) < 4:
                raise ValueError("Malformed VCD variable")
            kind, width_text, code = parts[:3]
            if kind in ("real", "realtime", "string", "port", "event"):
                raise ValueError("Unsupported VCD variable kind: " + kind)
            width = int(width_text)
            if width < 1 or width > 65536:
                raise ValueError("Invalid or excessively wide VCD variable")
            ref = parts[3:]
            bit_range = ""
            if len(ref) > 1 and re.fullmatch(r"\[-?\d+:-?\d+\]", ref[-1]):
                bit_range = ref.pop()
            name = ".".join(scope + ["".join(ref)])
            if name in signals or (code in widths and widths[code] != width):
                raise ValueError("Conflicting VCD variable: " + name)
            signals[name] = Signal(name, code, width, kind, bit_range)
            widths[code] = width
            events.setdefault(code, [])
        elif token == "$enddefinitions":
            if block() or not header or scope:
                raise ValueError("Malformed VCD enddefinitions or unclosed scope")
            header = False
        elif token in ("$dumpvars", "$dumpall", "$dumpon", "$dumpoff"):
            if header or dump_block:
                raise ValueError("Misplaced or nested VCD dump block")
            dump_block = True
        elif token == "$end":
            if not dump_block:
                raise ValueError("Unexpected VCD $end")
            dump_block = False
        elif token.startswith("#"):
            if header or dump_block:
                raise ValueError("Timestamp inside header or unclosed dump block")
            new_tick = int(token[1:])
            if new_tick < tick:
                raise ValueError("Non-monotonic VCD timestamp")
            tick = new_tick
        else:
            if header:
                raise ValueError("Unexpected VCD header token: " + token)
            if token[:1].lower() in ("r", "s", "p") or token.startswith("$"):
                raise ValueError("Unsupported VCD record: " + token)
            if token[:1].lower() == "b":
                value = token[1:].lower()
                code = next(it, None)
            elif token[:1].lower() in ("0", "1", "x", "z"):
                value, code = token[0].lower(), token[1:]
            else:
                raise ValueError("Malformed VCD change: " + token)
            if code not in widths or not re.fullmatch("[01xz]+", value):
                raise ValueError("Unknown identifier or malformed VCD value")
            width = widths[code]
            if len(value) > width:
                raise ValueError("Value wider than declared VCD signal")
            value = value.rjust(width, value[0] if value[0] in "xz" else "0")
            seq = events[code]
            count += 1
            if count > max_events:
                raise ValueError("VCD event limit reached; narrow the simulator capture")
            if seq and seq[-1][0] == tick:
                if seq[-1][1] != value:
                    collapsed += 1
                seq[-1] = (tick, value)
            elif not seq or seq[-1][1] != value:
                seq.append((tick, value))
    if header or timescale is None or not signals:
        raise ValueError("Incomplete VCD header, timescale, or signal declarations")
    if dump_block:
        raise ValueError("Unterminated VCD dump block")
    return Trace(timescale, signals, events, tick, collapsed)


def select_signals(trace, patterns):
    selected = []
    for pattern in patterns:
        matches = [name for name in trace.signals if fnmatch.fnmatchcase(name, pattern)]
        # An exact name with square brackets must not be treated only as a glob.
        if pattern in trace.signals:
            matches = [pattern]
        if not matches:
            raise ValueError("No VCD signal matches: " + pattern)
        selected.extend(name for name in matches if name not in selected)
    if not selected or len(selected) > 32:
        raise ValueError("Select 1 to 32 signals per readable figure")
    return [trace.signals[name] for name in selected]


def intervals(trace, signal, start, end):
    seq = trace.events[signal.code]
    index = bisect.bisect_right([t for t, _ in seq], start)
    value = seq[index - 1][1] if index else "x" * signal.width
    cursor = start
    for tick, next_value in seq[index:]:
        if tick >= end:
            break
        yield cursor, tick, value
        cursor, value = tick, next_value
    yield cursor, end, value


def value_label(value):
    if "x" in value or "z" in value:
        return value if len(value) <= 16 else value[:7] + "..." + value[-7:]
    return "0x" + format(int(value, 2), "0" + str((len(value) + 3) // 4) + "X")


def render_svg(trace, selected, start, end, title, origin, digest, filename):
    if not 0 <= start < end <= trace.last_tick:
        raise ValueError("Window must satisfy 0 <= start < end <= final VCD timestamp")
    width, label_width, plot_width, row_height = 1440, 370, 1010, 57
    height = 190 + row_height * len(selected)
    e = html.escape
    origin_label = {
        "simulator": "VCD TRACE — check the accompanying simulation result",
        "published-historical": "PUBLISHED HISTORICAL TRACE — existing evidence; not a new simulation",
        "illustrative": "ILLUSTRATIVE EXPECTED BEHAVIOR — not a measured result",
        "tool-selftest": "RENDERER SELF-TEST — synthetic data; not project evidence",
    }[origin]
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           '<rect width="100%" height="100%" fill="#f8fafc"/>',
           '<style>text{font-family:DejaVu Sans,Arial,sans-serif} .signal{font-family:DejaVu Sans Mono,monospace;font-size:13px} .small{font-size:12px;fill:#475569}</style>',
           f'<text x="26" y="31" font-size="21" fill="#0f172a">{e(title[:112])}</text>',
           f'<text x="26" y="54" font-size="13" fill="#92400e">{e(origin_label)}</text>',
           f'<text x="26" y="76" class="small">Time in VCD ticks; 1 tick = {e(trace.timescale)}. Same-timestamp changes display their final value.</text>']
    def xpos(tick):
        return label_width + (tick - start) / (end - start) * plot_width
    for i in range(9):
        x = label_width + i * plot_width / 8
        tick = start + (end - start) * i / 8
        svg.append(f'<path d="M{x:.2f},105 V{height-67}" stroke="#dbe3ed"/>')
        svg.append(f'<text x="{x:.2f}" y="99" text-anchor="middle" class="small">{tick:g}</text>')
    for row, signal in enumerate(selected):
        y = 119 + row * row_height
        label = signal.name
        if len(label) > 43:
            label = "..." + label[-40:]
        svg.append(f'<text x="26" y="{y+16}" class="signal"><title>{e(signal.name)}</title>{e(label)}</text>')
        svg.append(f'<text x="26" y="{y+32}" class="small">{signal.width} bit{e(signal.bit_range and " " + signal.bit_range)}</text>')
        previous_y = None
        for left, right, value in intervals(trace, signal, start, end):
            x1, x2 = xpos(left), xpos(right)
            if x2 <= x1:
                continue
            if signal.width == 1 and value in ("0", "1"):
                yy = y + (3 if value == "1" else 31)
                if previous_y is not None and previous_y != yy:
                    svg.append(f'<path d="M{x1:.2f},{previous_y} V{yy}" stroke="#0369a1" stroke-width="2"/>')
                svg.append(f'<path d="M{x1:.2f},{yy} H{x2:.2f}" stroke="#0369a1" stroke-width="2"/>')
                previous_y = yy
            else:
                previous_y = None
                color = "#b45309" if "x" in value or "z" in value else "#0369a1"
                tip = min(4, (x2 - x1) / 4)
                points = f'{x1:.2f},{y+17} {x1+tip:.2f},{y+3} {x2-tip:.2f},{y+3} {x2:.2f},{y+17} {x2-tip:.2f},{y+31} {x1+tip:.2f},{y+31}'
                svg.append(f'<polygon points="{points}" fill="#fff" stroke="{color}" stroke-width="1.5"><title>{e(value)}</title></polygon>')
                label_value = value if signal.width == 1 else value_label(value)
                if (x2 - x1) > 8 * len(label_value) + 6:
                    svg.append(f'<text x="{(x1+x2)/2:.2f}" y="{y+22}" text-anchor="middle" class="signal" fill="{color}">{e(label_value)}</text>')
        svg.append(f'<path d="M26,{y+43} H1408" stroke="#e2e8f0"/>')
    svg += [f'<text x="26" y="{height-38}" class="small">Source: {e(filename)} | SHA-256: {digest}</text>',
            f'<text x="26" y="{height-17}" class="small">A waveform is evidence of recorded signal values; it does not establish functional, protocol, or timing closure.</text>', '</svg>']
    return "\n".join(svg) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vcd", type=Path, required=True)
    parser.add_argument("--list-signals", action="store_true")
    parser.add_argument("--signals", nargs="+")
    parser.add_argument("--start", type=int, default=0, help="start in source VCD ticks")
    parser.add_argument("--end", type=int, help="end in source VCD ticks (default: final timestamp)")
    parser.add_argument("--max-events", type=int, default=2_000_000)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--title", default="Digital simulation waveform")
    parser.add_argument("--origin", choices=["simulator", "published-historical", "illustrative", "tool-selftest"])
    args = parser.parse_args(argv)
    try:
        trace = parse_vcd(args.vcd, args.max_events)
        if args.list_signals:
            print(json.dumps({"timescale": trace.timescale, "last_tick": trace.last_tick,
                              "signals": [vars(s) for s in trace.signals.values()]}, indent=2))
            return 0
        if not args.signals or not args.output or not args.origin:
            raise ValueError("Rendering requires --signals, --output, and an explicit --origin")
        if args.output.suffix.lower() != ".svg":
            raise ValueError("Output must have the .svg extension")
        if args.output.exists() or args.output.with_suffix(".json").exists():
            raise ValueError("Output already exists; choose a fresh run directory or figure name")
        chosen = select_signals(trace, args.signals)
        end = trace.last_tick if args.end is None else args.end
        digest = hashlib.sha256(args.vcd.read_bytes()).hexdigest()
        svg = render_svg(trace, chosen, args.start, end, args.title, args.origin, digest, args.vcd.name)
        metadata = {"schema_version": 1, "origin": args.origin, "source_filename": args.vcd.name,
                    "source_sha256": digest, "timescale": trace.timescale, "start_tick": args.start,
                    "end_tick": end, "source_final_tick": trace.last_tick,
                    "signals": [vars(s) for s in chosen], "same_tick_collapses": trace.same_tick_collapses,
                    "functional_result": "NOT_ASSESSED_BY_RENDERER"}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(svg, encoding="utf-8")
        args.output.with_suffix(".json").write_text(json.dumps(metadata, indent=2)+"\n", encoding="utf-8")
        print(json.dumps({"rendered": str(args.output), "source_sha256": digest,
                          "functional_result": "NOT_ASSESSED_BY_RENDERER"}))
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print("VCD_RENDER_ERROR: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
