#!/usr/bin/env python3
"""Generate the constant tables used by json.mojo's float conversion.

Both tables are computed from exact integer arithmetic and written into
json.mojo between the BEGIN/END GENERATED FLOAT TABLES markers.

  _POW5_128     Eisel-Lemire (parsing). For q in [-342, 308], 5^q
                normalized to a 128-bit integer with the top bit set,
                stored as (high, low) UInt64 pairs. Positive powers are
                truncated; negative powers are 2^b // 5^-q + 1, as in
                fast_float's script/table_generation.py.

  _SCHUBFACH_G  Schubfach (printing). For k in [-324, 292], with
                10^-k = beta * 2^r and 2^125 <= beta < 2^126,
                g = floor(beta) + 1 stored as (g >> 63, g mod 2^63), as in
                Giulietti's paper and OpenJDK's MathUtils.

Usage:
  python3 tools/gen_float_tables.py           rewrite json.mojo
  python3 tools/gen_float_tables.py --check   exit 1 if json.mojo is stale
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "json.mojo")
BEGIN = "# BEGIN GENERATED FLOAT TABLES"
END = "# END GENERATED FLOAT TABLES"

POW5_MIN_Q, POW5_MAX_Q = -342, 308
G_MIN_K, G_MAX_K = -324, 292
MASK64 = (1 << 64) - 1
MASK63 = (1 << 63) - 1


def pow5_128(q: int) -> int:
    if q >= 0:
        v = 5**q
        while v < (1 << 127):
            v <<= 1
        while v >= (1 << 128):
            v >>= 1
        return v
    p = 5**-q
    z = p.bit_length()  # smallest z with 2^z >= p (p is never a power of 2)
    b = z + 127 if q >= -27 else 2 * z + 128
    c = (1 << b) // p + 1
    while c >= (1 << 128):
        c >>= 1
    return c


def schubfach_g(k: int) -> int:
    # beta = 10^-k * 2^-r with 2^125 <= beta < 2^126; g = floor(beta) + 1
    if k <= 0:
        n = 10**-k
        r = n.bit_length() - 126
        floor_beta = n >> r if r >= 0 else n << -r
    else:
        d = 10**k
        s = 125 + d.bit_length()  # candidate -r
        floor_beta = (1 << s) // d
        while floor_beta >= (1 << 126):
            s -= 1
            floor_beta = (1 << s) // d
        while floor_beta < (1 << 125):
            s += 1
            floor_beta = (1 << s) // d
    assert (1 << 125) <= floor_beta < (1 << 126)
    return floor_beta + 1


def hex64(v: int) -> str:
    return f"0x{v:016X}"


def render() -> str:
    lines = [
        BEGIN + " (tools/gen_float_tables.py; do not edit)",
        "# fmt: off",
        f"comptime _POW5_128: InlineArray[UInt64, {2 * (POW5_MAX_Q - POW5_MIN_Q + 1)}] = [",
    ]
    for q in range(POW5_MIN_Q, POW5_MAX_Q + 1):
        v = pow5_128(q)
        lines.append(f"    {hex64(v >> 64)}, {hex64(v & MASK64)},  # 5^{q}")
    lines.append("]")
    lines.append(f"comptime _SCHUBFACH_G: InlineArray[UInt64, {2 * (G_MAX_K - G_MIN_K + 1)}] = [")
    for k in range(G_MIN_K, G_MAX_K + 1):
        g = schubfach_g(k)
        lines.append(f"    {hex64(g >> 63)}, {hex64(g & MASK63)},  # k = {k}")
    lines.append("]")
    lines.append("# fmt: on")
    lines.append(END)
    return "\n".join(lines)


def main() -> int:
    source = open(TARGET, encoding="utf-8").read()
    if BEGIN not in source or END not in source:
        print(f"markers not found in {TARGET}", file=sys.stderr)
        return 1
    start = source.index(BEGIN)
    end = source.index(END) + len(END)
    updated = source[:start] + render() + source[end:]
    if "--check" in sys.argv:
        if updated != source:
            print("json.mojo float tables are stale: run tools/gen_float_tables.py")
            return 1
        print("float tables up to date")
        return 0
    with open(TARGET, "w", encoding="utf-8") as f:
        f.write(updated)
    print("float tables written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
