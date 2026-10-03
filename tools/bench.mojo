# Throughput benchmark: parse and serialize MB/s for typical shapes.
#
# Run with `pixi run bench` (builds with -O3). Data is generated
# deterministically, so numbers are comparable across commits. Reports the
# best of several runs; informational only (not a CI gate).

from std.memory import bitcast
from std.time import perf_counter_ns

from json import json_number, parse_json


struct _Rng:
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        # xorshift64*
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        return self.state * 0x2545F4914F6CDD1D


def _ints(n: Int) -> String:
    var rng = _Rng(1)
    var s = String("[")
    for i in range(n):
        if i > 0:
            s += ","
        s += String(Int(rng.next() >> 40))
    return s + "]"


def _floats9(n: Int) -> String:
    # 9 significant digits: Clinger fast path
    var rng = _Rng(2)
    var s = String("[")
    for i in range(n):
        if i > 0:
            s += ","
        s += "0." + String(100_000_000 + Int(rng.next() % 900_000_000))
    return s + "]"


def _floats17(n: Int) -> String:
    # Shortest repr of random doubles in [0, 1): ~17 digits, Eisel-Lemire
    var rng = _Rng(3)
    var s = String("[")
    for i in range(n):
        if i > 0:
            s += ","
        var x = (
            bitcast[DType.float64]((rng.next() >> 12) | 0x3FF0000000000000)
            - 1.0
        )
        s += String(json_number(x))  # shortest repr-style text
    return s + "]"


def _mixed(n: Int) -> String:
    var rng = _Rng(4)
    var s = String("[")
    for i in range(n):
        if i > 0:
            s += ","
        s += '{"id":' + String(i) + ',"name":"user' + String(i) + '"'
        s += ',"score":' + String(Float64(Int(rng.next() % 100000)) / 100.0)
        s += ',"tags":["a","b","c"],"active":' + (
            "true" if i % 2 == 0 else "false"
        )
        s += ',"bio":"h\\u00e9llo \\"quoted\\" text"'
        s += ',"geo":{"lat":' + String(
            Float64(Int(rng.next() % 18000000)) / 100000.0 - 90.0
        )
        s += ',"lng":' + String(
            Float64(Int(rng.next() % 36000000)) / 100000.0 - 180.0
        )
        s += "}}"
    return s + "]"


def _report(name: String, text: String) raises:
    var mb = Float64(text.byte_length()) / 1e6
    var best_parse = Int.MAX
    var best_write = Int.MAX
    var v = parse_json(text)
    for _ in range(7):
        var t0 = perf_counter_ns()
        var parsed = parse_json(text)
        var t1 = perf_counter_ns()
        var out = String(v)
        var t2 = perf_counter_ns()
        _ = len(parsed)
        _ = out.byte_length()
        best_parse = min(best_parse, Int(t1 - t0))
        best_write = min(best_write, Int(t2 - t1))
    var parse_ms = Float64(best_parse) / 1e6
    var write_ms = Float64(best_write) / 1e6
    print(
        name,
        "|",
        mb,
        "MB | parse",
        parse_ms,
        "ms (",
        Int(mb / (parse_ms / 1000.0)),
        "MB/s ) | serialize",
        write_ms,
        "ms (",
        Int(mb / (write_ms / 1000.0)),
        "MB/s )",
    )


def main() raises:
    _report("ints     ", _ints(1_000_000))
    _report("floats9  ", _floats9(500_000))
    _report("floats17 ", _floats17(500_000))
    _report("mixed    ", _mixed(30_000))
