# Peak-memory probe: parse one generated shape and report input size; run
# under `/usr/bin/time` (see memprobe.sh) to read peak RSS. With a second
# argument it skips parsing, giving the baseline (runtime + input text) to
# subtract. Report-only.

from std.sys import argv

from json import parse_json


def _repeat(item: String, n: Int) -> String:
    var s = String(capacity=item.byte_length() * n + 2)
    s += "["
    for i in range(n):
        if i > 0:
            s += ","
        s += item
    return s + "]"


def main() raises:
    var shape = String(argv()[1])
    var text: String
    if shape == "zeros":
        text = _repeat("0", 5_000_000)
    elif shape == "empty_objects":
        text = _repeat("{}", 3_000_000)
    elif shape == "empty_arrays":
        text = _repeat("[]", 3_000_000)
    else:  # mixed
        text = _repeat(
            '{"id":12345,"name":"user","score":12.5,"tags":["a","b"],"ok":true}',
            150_000,
        )
    if len(argv()) > 2:  # baseline: same input, no parse
        print(shape, text.byte_length(), 0)
        return
    var doc = parse_json(text)
    print(shape, text.byte_length(), len(doc))
