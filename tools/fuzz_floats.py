#!/usr/bin/env python3
"""Differential fuzz of number parsing and printing against CPython.

Generates random JSON numbers (random doubles, long mantissas, exact
halfway points between adjacent doubles, subnormals, huge exponents,
powers of two and ten +/- 1 ulp, values at repr's layout boundaries),
checks parse_json returns the bit-identical double CPython does, then
checks json.mojo serializes every value exactly as CPython's repr()
(byte for byte: shortest round-trip digits in the same layout).

Usage: python3 tools/fuzz_floats.py [count] [seed]
"""

import json
import os
import random
import struct
import subprocess
import sys
from decimal import Decimal, getcontext

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".cache")


def bits(x: float) -> int:
    return struct.unpack("<q", struct.pack("<d", x))[0]


def from_bits(b: int) -> float:
    return struct.unpack("<d", struct.pack("<q", b))[0]


def digits(rng: random.Random, n: int) -> str:
    return str(rng.randint(1, 9)) + "".join(rng.choice("0123456789") for _ in range(n - 1))


def random_double(rng: random.Random) -> float:
    while True:
        x = from_bits(rng.getrandbits(63))
        if x == x and abs(x) != float("inf"):
            return x


def gen(rng: random.Random) -> str:
    k = rng.random()
    if k < 0.25:
        return repr(random_double(rng))
    if k < 0.35:
        # 16-25 digit mantissas across the 128-bit path's exponent range
        return f"{digits(rng, rng.randint(16, 25))}e{rng.randint(-21, 19)}"
    if k < 0.45:
        return f"{digits(rng, rng.randint(1, 40))}.{digits(rng, rng.randint(1, 40))}e{rng.randint(-345, 300)}"
    if k < 0.6:
        return "0." + "0" * rng.randint(0, 25) + digits(rng, rng.randint(1, 30))
    if k < 0.7:
        return digits(rng, rng.randint(1, 40))
    if k < 0.85:
        # Exact midpoint between adjacent doubles (all ~770 digits for
        # subnormals): the hardest rounding case. Nudged versions sit one
        # unit in the last digit above or below the midpoint.
        if rng.random() < 0.5:
            x = from_bits(rng.randrange(0, 1 << 52))  # subnormal
        else:
            x = abs(random_double(rng)) or 1.0
        mid = (Decimal(x) + Decimal(from_bits(bits(x) + 1))) / 2
        text = format(mid, "e")
        nudge = rng.random()
        if nudge < 0.25:
            mantissa, exp = text.split("e")
            text = mantissa + ("1" if "." in mantissa else ".1") + "e" + exp
        elif nudge < 0.5:
            mantissa, exp = text.split("e")
            significand = mantissa.replace(".", "")
            if len(significand) > 1 and significand[-1] != "0":
                text = mantissa[:-1] + str(int(mantissa[-1]) - 1) + "e" + exp
        return text
    if k < 0.9:
        # Powers of two and ten, +/- 1 ulp (irregular spacing, exactness)
        x = 2.0 ** rng.randint(-1074, 1023) if rng.random() < 0.5 else float(f"1e{rng.randint(-323, 308)}")
        x = from_bits(bits(x) + rng.choice([-1, 0, 0, 1]))
        return repr(x) if x != 0 and abs(x) != float("inf") else "1.0"
    if k < 0.95:
        # repr layout boundaries: decpt around -4 and 16, integral floats
        x = rng.choice([
            rng.uniform(1e-6, 1e-3),
            rng.uniform(1e14, 1e18),
            float(rng.randint(1, 2**60)),
            float(rng.randint(1, 10**6)) * 10.0 ** rng.randint(0, 20),
        ])
        return repr(x)
    return f"{digits(rng, rng.randint(1, 20))}e{rng.choice([-324, -323, -320, -310, -308, 307, 308])}"


def main() -> int:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    getcontext().prec = 1200
    rng = random.Random(seed)
    cases = []
    while len(cases) < count:
        text = gen(rng)
        if rng.random() < 0.5:
            text = "-" + text
        value = json.loads(text)  # also asserts the text is valid JSON
        if isinstance(value, int):
            value = float(value)
        if abs(value) == float("inf"):
            continue
        cases.append([text, str(bits(value))])

    os.makedirs(CACHE, exist_ok=True)
    corpus = os.path.join(CACHE, "fuzz_floats.json")
    printed_path = os.path.join(CACHE, "fuzz_floats.out")
    with open(corpus, "w") as f:
        json.dump(cases, f)
    result = subprocess.run(
        ["mojo", "run", "-I", ROOT, os.path.join(ROOT, "tools", "fuzz_floats.mojo"), corpus, printed_path]
    )
    if result.returncode != 0:
        return result.returncode

    failures = 0
    printed = open(printed_path).read().split("\n")[:-1]
    for (text, expected), out in zip(cases, printed):
        want = repr(from_bits(int(expected)))
        if out != want:
            failures += 1
            if failures <= 10:
                print(f"PRINT MISMATCH: {text} printed as {out}, CPython repr {want}")
    print(f"{len(printed)} values serialized, {failures} differ from CPython repr")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
