# Runs parse_json over a JSONTestSuite corpus prepared by conformance.py.
#
# Input (argv[1]): JSON array of [filename, document] pairs.
# y_* must parse, n_* must fail, i_* (implementation-defined) are reported.

from std.sys import argv

from json import parse_json


def main() raises:
    var f = open(String(argv()[1]), "r")
    var cases = parse_json(f.read())
    f.close()
    var failures = 0
    var i_accepted = 0
    var i_rejected = 0
    for k in range(len(cases)):
        var row = cases[k]
        var name = row.get_string(0)
        var accepted = True
        try:
            _ = parse_json(row.get_string(1))
        except:
            accepted = False
        if name.startswith("y_") and not accepted:
            failures += 1
            print("FAIL (should accept):", name)
        elif name.startswith("n_") and accepted:
            failures += 1
            print("FAIL (should reject):", name)
        elif name.startswith("i_"):
            if accepted:
                i_accepted += 1
            else:
                i_rejected += 1
    print(
        len(cases),
        "cases,",
        failures,
        "failures; implementation-defined accepted/rejected:",
        i_accepted,
        "/",
        i_rejected,
    )
    if failures > 0:
        raise Error(String(failures) + " conformance failure(s)")
