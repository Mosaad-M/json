# Parser fuzz harness driven by fuzz_parser.py.
#
# Input (argv[1]): JSON array of documents (strings).
# Output (argv[2]): one line per document: "0<error message>" if it raised,
# else "1<serialized doc>\t<accessor dump>". The accessor dump re-serializes
# the document using only keys()/get(key)/get(i)/len(), so lookups (and the
# side indexes behind them) are checked against CPython too.
#
# For every accepted document it also checks, and reports failures for:
#   * the slot-layout invariants (JsonDoc._validate);
#   * equivalence of the flat document and its JsonValue tree.

from std.sys import argv
from std.time import perf_counter_ns

from json import JsonRef, json_string, parse_json


def dump[o: ImmOrigin](r: JsonRef[o], mut out: String) raises:
    """Serialize r using only the read accessors."""
    if r.is_array():
        out += "["
        for i in range(len(r)):
            if i > 0:
                out += ", "
            dump(r[i], out)
        out += "]"
    elif r.is_object():
        out += "{"
        var keys = r.keys()
        for i in range(len(keys)):
            if i > 0:
                out += ", "
            if keys[i] not in r or not r.has_key(keys[i]):
                raise Error("key listed by keys() not found: " + keys[i])
            out += String(json_string(keys[i])) + ": "
            dump(r[keys[i]], out)
        out += "}"
    else:
        out += String(r)


def main() raises:
    var args = argv()
    var f = open(String(args[1]), "r")
    var docs = parse_json(f.read())
    f.close()
    var out = String()
    var slowest_ns = 0
    var slowest = 0
    var problems = 0
    for k in range(len(docs)):
        var text = docs.get_string(k)
        var t0 = perf_counter_ns()
        try:
            var doc = parse_json(text)
            var serialized = String(doc)
            var dt = Int(perf_counter_ns() - t0)
            if dt > slowest_ns:
                slowest_ns = dt
                slowest = k
            try:
                doc._validate()
            except e:
                problems += 1
                print("INVARIANT #", k, ":", String(e))
            if String(doc.to_value()) != serialized:
                problems += 1
                print("DOC != TREE #", k)
            var accessed = String()
            dump(doc.root(), accessed)
            out += "1" + serialized + "\t" + accessed + "\n"
        except e:
            var msg = String(e).replace("\n", " ")
            out += "0" + msg + "\n"
    var o = open(String(args[2]), "w")
    o.write(out)
    o.close()
    print(
        len(docs),
        "documents; slowest #",
        slowest,
        "took",
        Float64(slowest_ns) / 1e6,
        "ms;",
        problems,
        "invariant/equivalence failures",
    )
    if problems > 0:
        raise Error(String(problems) + " invariant/equivalence failure(s)")
