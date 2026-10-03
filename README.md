# json — Strict JSON for Mojo

A JSON parser and serializer in pure [Mojo](https://www.modular.com/mojo):
one file, no dependencies, no FFI.

- **Strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)** parsing — passes every
  accept/reject case of [JSONTestSuite](https://github.com/nst/JSONTestSuite) that can be
  expressed as a Mojo `String`.
- **Exact numbers** — integers that fit in Int64 are kept exactly; everything else is
  converted to the *correctly rounded* Float64 (bit-identical to CPython in fuzzing).
- **Full Unicode** — `\uXXXX` escapes, including surrogate pairs, decode to UTF-8.
- **Safe on hostile input** — configurable nesting limit instead of a stack overflow.
- **Round-trips** — serialized output parses back to the same values, bit for bit.

## Install

`json.mojo` is self-contained. Copy it into your project, or add this repo as a
submodule and put it on the import path:

```bash
mojo run -I path/to/json your_program.mojo
```

Requires Mojo `>= 1.0.0`.

## Quick start

```mojo
from json import parse_json, json_object, json_array, json_string, json_int

def main() raises:
    var doc = parse_json('{"name": "mojo", "version": 1, "tags": ["fast", "safe"]}')

    # Leaf accessors read straight out of the tree (no copies)
    print(doc.get_string("name"))        # mojo
    print(doc.get_int("version"))        # 1
    print(doc.get_array_len("tags"))     # 2

    # Subscripts return deep copies of subtrees
    var tags = doc["tags"]
    print(tags.get_string(0))            # fast
    print("name" in doc)                 # True

    # Build documents
    var out = json_object()
    out.set("ok", json_int(1))
    var list = json_array()
    list.append(json_string("a"))
    out.set("items", list^)
    print(out)                           # {"ok": 1, "items": ["a"]}
```

## API

### Parsing

| | |
|---|---|
| `parse_json(s, max_depth=512) raises -> JsonValue` | Parse one JSON document. Raises with a position on any error. |

### `JsonValue`

| Kind | Methods |
|---|---|
| Type checks | `is_null()` `is_bool()` `is_number()` `is_int()` `is_string()` `is_array()` `is_object()` |
| Scalars | `as_bool()` `as_number() -> Float64` `as_int() -> Int` `as_string()` |
| Leaf accessors (no copy) | `get_string(k)` `get_int(k)` `get_number(k)` `get_bool(k)` — `k` is a key (`String`) or an index (`Int`); `get_array_len(key)` |
| Subtrees (deep copy) | `get(k)`, `v[k]` |
| Objects | `keys()` (insertion order) `has_key(key)` `key in v` `set(key, value)` |
| Arrays | `append(value)` |
| Other | `len(v)` (array/object size, string codepoints) · `Bool(v)` (Python-style truthiness) · `String(v)` / `print(v)` (serialize) · `copy()` |

All typed accessors raise if the value has the wrong kind, the key is missing, or the
index is out of bounds.

### Constructors

`json_null()` `json_bool(b)` `json_int(i)` `json_number(f)` `json_string(s)`
`json_array()` `json_object()`

## Semantics

**Numbers.** An integer literal that fits in Int64 is stored exactly (`is_int()` is
true; `as_int()` is exact, `as_number()` converts). Any other number is stored as the
nearest Float64. A number whose magnitude overflows Float64 (e.g. `1e400`) is a parse
error; one that underflows becomes `0.0`. `as_int()` on a float truncates toward zero
and raises if the value is outside Int64 range.

**Strings.** Escapes are decoded; `\uD83D\uDE00` becomes 😀. Unpaired surrogates,
unknown escapes, and raw control characters (U+0000–U+001F) are errors. Input must be
valid UTF-8, which every Mojo `String` is.

**Objects.** Keys keep insertion order. For a duplicate key, the last value wins and
the key keeps its first position. Lookups use a linear scan up to 16 keys and a hash
index above that.

**Nesting.** Arrays and objects may nest `max_depth` (default 512) levels deep; deeper
input raises instead of overflowing the stack.

**Serialization.** Output uses `", "` and `": "` separators. Numbers are written exactly
like Python's `json.dumps` / `repr`, so floats keep their float-ness on a round trip:

| Value | Output | | Value | Output |
|---|---|---|---|---|
| `json_int(100)` | `100` | | `1e15` | `1000000000000000.0` |
| `json_number(100.0)` | `100.0` | | `1e16` | `1e+16` |
| `0.1` | `0.1` | | `0.0001` | `0.0001` |
| `-0.0` | `-0.0` | | `0.00001` | `1e-05` |

Float digits are the shortest that parse back to the same double (closest, ties to
even). `inf` and `nan` (which only arise from `json_number`) are written as `null`, as
in JavaScript.

**Performance.** `get()` and `[]` deep-copy the subtree they return. In hot paths,
use the leaf accessors (`get_string`, `get_int`, …), which copy only the scalar.
Number conversion uses the standard fast algorithms: Clinger's fast path and
**Eisel-Lemire** (as in fast_float, Rust, Go) for parsing, with an exact big-integer
fallback for the rare undecidable cases, and **Schubfach** (as in Java 19+) for printing.
`pixi run bench` reports parse/serialize throughput.

## Security

`parse_json` is designed for untrusted input:

- **No crashes.** Fuzzed with 300k+ mutated documents (with stdlib bounds checks on);
  every input either parses or raises. Every unchecked pointer read is preceded by a
  bounds check or grammar validation.
- **Bounded nesting.** `max_depth` (default 512) prevents stack exhaustion.
- **Bounded work per byte.** Parsing is linear in the input. Even crafted ~800-digit
  floats sitting exactly between two doubles (the worst case for exact rounding) parse
  at ~95 MB/s, as fast as typical input. Objects of any size use a hash index, so many keys or
  repeated duplicate keys stay linear.
- **Safe error messages.** Errors never echo raw control or non-ASCII bytes from the
  input (they are shown as hex), so they are safe to log.

What callers should still do:

- **Cap input size.** The parsed tree takes roughly 50–90x the input size in memory
  for inputs made of tiny values (`[0,0,0,…]`, `[[],[],…]`); typical documents take far
  less. Reject oversized payloads before parsing.
- **Lower `max_depth`** if you don't expect deep documents.
- **Hash flooding.** Mojo 1.0's `String` hash is not seeded per process, so an attacker
  who can craft colliding keys could slow lookups in very large objects. No practical
  attack is known; capping input size bounds the impact.
- Trees built through the API (`append`/`set`) have no depth limit; copying, printing,
  or destroying one nested ~10,000 deep can exhaust the stack.

## Development

```bash
pixi run test          # unit tests
pixi run conformance   # JSONTestSuite (clones it into .cache/ on first run)
pixi run fuzz          # number parse/print differential fuzz against CPython
pixi run fuzz-parser   # mutated-document differential fuzz against CPython json
pixi run bench         # parse/serialize throughput
pixi run gen-tables    # regenerate the float tables in json.mojo (--check in CI)
pixi run format        # mojo format
```

`conformance`, `fuzz`, and `fuzz-parser` need `python3` on the PATH. CI runs all of
them on Linux and macOS.

## License

MIT — see [LICENSE](LICENSE).
