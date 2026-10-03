#!/usr/bin/env python3
"""Differential fuzz of parse_json against CPython's json module.

Mutates seed documents (JSONTestSuite y_ files plus built-in seeds) and
checks, for every input, that json.mojo:
  * never crashes (the harness must exit cleanly);
  * accepts exactly what strict JSON accepts. CPython is the oracle, made
    strict: NaN/Infinity literals, lone surrogates, and numbers that
    overflow Float64 count as invalid;
  * produces the same value (numbers compared as Float64 unless both
    sides are exact Int64 integers), both when serialized and when
    re-read through keys()/get(key)/get(i)/len();
  * passes JsonDoc's layout invariant checks, and matches its JsonValue
    tree (checked by the Mojo harness, which then exits non-zero).

Usage: python3 tools/fuzz_parser.py [count] [seed] [--binary PATH]
--binary runs a prebuilt harness (e.g. an AddressSanitizer build) instead
of `mojo run`.
"""

import json
import math
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".cache")
INT64 = (-(2**63), 2**63 - 1)

SEEDS = [
    '{"a": [1, 2.5, -3e2, true, false, null], "b": {"c": "d\\n\\u00e9\\ud83d\\ude00"}}',
    '[0, -0, 0.0, 1E+2, 1e-2, 123456789012345678901234567890, 9223372036854775807]',
    '{"k0": 0, "k1": 1, "k2": 2, "k3": 3, "k4": 4, "k5": 5, "k6": 6, "k7": 7, '
    '"k8": 8, "k9": 9, "k10": 10, "k11": 11, "k12": 12, "k13": 13, "k14": 14, '
    '"k15": 15, "k16": 16, "k1": "dup"}',
    '"\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000\\u001f"',
    '[[[[[[[[[[]]]]]]]]]]',
    '{"":{"":{"":[{"":""}]}}}',
    '1.7976931348623157e308',
    '5e-324',
    # Large containers: array offset tables and nested sorted key indexes
    '[' + ', '.join('{"i": %d, "v": [%d, {"x": null}]}' % (i, i) for i in range(20)) + ']',
    '{' + ', '.join('"k%d": {%s}' % (i, ', '.join('"n%d": %d' % (j, j) for j in range(17))) for i in range(17)) + '}',
]
TOKENS = list('{}[]",:\\0123456789eE.-+ tfnlrsu\t\n') + [
    "\\u", "\\ud800", "\\udc00", "true", "null", "1e999", "é", " ", "😀",
    "\x00", "\x1f", "\x7f", "NaN", "Infinity", "[" * 50, "]" * 50, '"' * 2,
]


class Invalid(Exception):
    pass


def oracle(text):
    """Strict-JSON value of text, or raise Invalid."""
    def no_constant(name):
        raise Invalid(name)

    def check(v):
        if isinstance(v, float) and math.isinf(v):
            raise Invalid("overflow")
        if isinstance(v, str) and any(0xD800 <= ord(ch) <= 0xDFFF for ch in v):
            raise Invalid("lone surrogate")

    def pairs_hook(pairs):
        # Check every pair: dict() would hide an invalid duplicate-key value
        for k, v in pairs:
            check(k)
            check(v)
        return dict(pairs)

    try:
        value = json.loads(
            text,
            parse_constant=no_constant,
            object_pairs_hook=pairs_hook,
            parse_float=lambda s: _checked(float(s), check),
            parse_int=lambda s: int(s),
        )
    except (ValueError, RecursionError, Invalid):
        raise Invalid()
    if isinstance(value, str):
        check(value)
    _walk_lists(value, check)
    return value


def _checked(v, check):
    check(v)
    return v


def _walk_lists(v, check):
    """Check scalars inside arrays (objects are checked by pairs_hook)."""
    if isinstance(v, list):
        for x in v:
            check(x)
            _walk_lists(x, check)
    elif isinstance(v, dict):
        for x in v.values():
            _walk_lists(x, check)


def depth(text):
    d = m = 0
    in_str = esc = False
    for ch in text:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "[{":
            d += 1
            m = max(m, d)
        elif ch in "]}":
            d -= 1
    return m


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        exact_a = isinstance(a, int) and INT64[0] <= a <= INT64[1]
        exact_b = isinstance(b, int) and INT64[0] <= b <= INT64[1]
        if exact_a and exact_b:
            return a == b
        return float(a) == float(b)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return list(a) == list(b) and all(same(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def mutate(rng, text):
    for _ in range(rng.randint(1, 4)):
        op = rng.random()
        i = rng.randint(0, len(text))
        if op < 0.3:
            text = text[:i] + rng.choice(TOKENS) + text[i:]
        elif op < 0.55 and text:
            text = text[:i] + text[i + 1:]
        elif op < 0.8 and text:
            text = text[:i] + rng.choice(TOKENS) + text[i + 1:]
        elif op < 0.9:
            text = text[:i]
        else:
            j = rng.randint(0, len(text))
            text = text[:i] + text[min(i, j):max(i, j)] + text[i:]
    return text


def seeds():
    out = list(SEEDS)
    suite = os.path.join(CACHE, "JSONTestSuite", "test_parsing")
    if os.path.isdir(suite):
        for name in sorted(os.listdir(suite)):
            if name.startswith("y_"):
                try:
                    out.append(open(os.path.join(suite, name), "rb").read().decode("utf-8"))
                except UnicodeDecodeError:
                    pass
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    binary = None
    if "--binary" in sys.argv:
        binary = sys.argv[sys.argv.index("--binary") + 1]
        args.remove(binary)
    count = int(args[0]) if args else 20000
    rng = random.Random(int(args[1]) if len(args) > 1 else 1)

    pool = seeds()
    docs = list(pool)
    while len(docs) < count:
        docs.append(mutate(rng, rng.choice(pool)))
    # Stay under parse_json's default max_depth (512) and CPython's
    # recursion limit; depth limits are tested separately.
    docs = [d for d in docs if depth(d) <= 400]

    os.makedirs(CACHE, exist_ok=True)
    corpus = os.path.join(CACHE, "fuzz_parser.json")
    results = os.path.join(CACHE, "fuzz_parser.out")
    json.dump(docs, open(corpus, "w"))
    cmd = [binary] if binary else ["mojo", "run", "-I", ROOT, os.path.join(ROOT, "tools", "fuzz_parser.mojo")]
    proc = subprocess.run(cmd + [corpus, results])
    if proc.returncode != 0:
        print(f"HARNESS CRASHED (exit {proc.returncode})")
        return 1

    lines = open(results, encoding="utf-8").read().split("\n")[:-1]
    assert len(lines) == len(docs), (len(lines), len(docs))
    stats = {"accepted": 0, "rejected": 0}
    failures = 0
    for doc, line in zip(docs, lines):
        try:
            expected = ("ok", oracle(doc))
        except Invalid:
            expected = ("invalid", None)
        accepted = line[0] == "1"
        stats["accepted" if accepted else "rejected"] += 1
        problem = None
        if expected[0] == "ok" and not accepted:
            problem = f"rejected valid JSON ({line[1:]})"
        elif expected[0] == "invalid" and accepted:
            problem = "accepted invalid JSON"
        elif accepted:
            serialized, accessed = line[1:].split("\t")
            if not same(json.loads(serialized), expected[1]):
                problem = f"value mismatch: got {serialized[:200]}"
            elif not same(json.loads(accessed), expected[1]):
                problem = f"accessor (keys/get/len) mismatch: got {accessed[:200]}"
        if problem:
            failures += 1
            if failures <= 10:
                print(f"FAIL {problem}\n  input: {doc[:200]!r}")
    print(f"{len(docs)} inputs ({stats['accepted']} accepted, {stats['rejected']} rejected), {failures} disagreements with CPython")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
