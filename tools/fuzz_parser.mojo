# Parser fuzz harness driven by fuzz_parser.py.
#
# Input (argv[1]): JSON array of documents (strings).
# Output (argv[2]): one line per document: "1<serialized value>" if it
# parsed, "0<error message>" if it raised. Also reports the slowest case.

from std.sys import argv
from std.time import perf_counter_ns

from json import parse_json


def main() raises:
    var args = argv()
    var f = open(String(args[1]), "r")
    var docs = parse_json(f.read())
    f.close()
    var out = String()
    var slowest_ns = 0
    var slowest = 0
    for k in range(len(docs)):
        var text = docs.get_string(k)
        var t0 = perf_counter_ns()
        try:
            var v = parse_json(text)
            out += "1" + String(v) + "\n"
        except e:
            var msg = String(e).replace("\n", " ")
            out += "0" + msg + "\n"
        var dt = Int(perf_counter_ns() - t0)
        if dt > slowest_ns:
            slowest_ns = dt
            slowest = k
    var o = open(String(args[2]), "w")
    o.write(out)
    o.close()
    print(
        len(docs),
        "documents; slowest #",
        slowest,
        "took",
        Float64(slowest_ns) / 1e6,
        "ms",
    )
