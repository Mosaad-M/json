# Differential float check driven by fuzz_floats.py.
#
# Input (argv[1]): JSON array of [number text, expected IEEE-754 bits].
# Prints mismatches and writes String(json_number(x)) for every case to
# argv[2] so the driver can check the serializer round-trips.

from std.memory import bitcast
from std.sys import argv

from json import json_number, parse_json


def main() raises:
    var args = argv()
    var f = open(String(args[1]), "r")
    var cases = parse_json(f.read())
    f.close()
    var printed = String()
    var mismatches = 0
    for k in range(len(cases)):
        var text = cases[k].get_string(0)
        var expected = Int(cases[k].get_string(1))
        var got = parse_json(text).as_number()
        if Int(bitcast[DType.int64](got)) != expected:
            mismatches += 1
            print("PARSE MISMATCH:", text, "->", got)
        printed += String(json_number(got)) + "\n"
    var out = open(String(args[2]), "w")
    out.write(printed)
    out.close()
    print(len(cases), "cases,", mismatches, "parse mismatches")
    if mismatches > 0:
        raise Error(String(mismatches) + " parse mismatch(es)")
