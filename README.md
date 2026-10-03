# json — Strict JSON for Mojo

A JSON parser and serializer in pure [Mojo](https://www.modular.com/mojo):
one file, no dependencies, no FFI.

- **Strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)** parsing — passes every
  accept/reject case of [JSONTestSuite](https://github.com/nst/JSONTestSuite) that can be
  expressed as a Mojo `String`.
- **Exact numbers** — integers that fit in Int64 are kept exactly; everything else is
  converted to the *correctly rounded* Float64 (bit-identical to CPython in fuzzing).
- **Full Unicode** — `\uXXXX` escapes, including surrogate pairs, decode to UTF-8.
- **Flat, compact documents** — a parsed document is one block of 16-byte values plus
  a string arena: no per-value allocations, cheap to copy or free, and lookups return
  views instead of copies.
- **Safe on hostile input** — iterative (no recursion anywhere), bounded memory per input
  byte, no hash-flooding surface.
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

    print(doc.get_string("name"))        # mojo
    print(doc.get_int("version"))        # 1

    # Lookups return views into the document (no copies)
    var tags = doc["tags"]
    print(tags.get_string(0))            # fast
    print("name" in doc)                 # True
    for tag in tags.items():
        print(tag)                       # "fast", then "safe"
    for member in doc.entries():
        print(member.key(), member.value)

    # Mutable copy of a parsed document
    var v = doc.to_value()
    v.set("version", json_int(2))

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
| `parse_json(s, max_depth=512) raises -> JsonDoc` | Parse one JSON document. Raises with a position on any error. |

### Reading: `JsonDoc` and `JsonRef`

`JsonDoc` is the parsed, read-only document; its methods act on the root value.
`JsonRef` is a view of any value inside a document: cheap to copy, and tied to the
document's lifetime by the compiler (a view cannot outlive its document).

| Kind | Methods (on both `JsonDoc` and `JsonRef`) |
|---|---|
| Type checks | `kind()` `is_null()` `is_bool()` `is_number()` `is_int()` `is_string()` `is_array()` `is_object()` |
| Scalars | `as_bool()` `as_number() -> Float64` `as_int() -> Int` `as_string()`; `JsonRef.as_string_slice()` (zero-copy) |
| Lookups (views) | `get(k)`, `v[k]` — `k` is a key (`String`) or an index (`Int`) |
| Leaf shortcuts | `get_string(k)` `get_int(k)` `get_number(k)` `get_bool(k)` `get_array_len(key)` |
| Objects | `keys()` (insertion order) `has_key(key)` `key in v` `entries()` (iterate members: `.key()`, `.value`) |
| Arrays | `items()` (iterate elements) |
| Other | `len(v)` (array/object size, string codepoints) · `Bool(v)` (Python-style truthiness) · `String(v)` / `print(v)` (serialize) · `to_value()` (mutable copy) · `JsonDoc.root()` |

### Building: `JsonValue`

A mutable tree for constructing or editing documents. Same read methods as above
(lookups return deep copies), plus `set(key, value)` on objects, `append(value)` on
arrays, and `copy()`.

Constructors: `json_null()` `json_bool(b)` `json_int(i)` `json_number(f)`
`json_string(s)` `json_array()` `json_object()`.

All typed accessors raise if the value has the wrong kind, the key is missing, or the
index is out of bounds.

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
the key keeps its first position. In parsed documents, lookups scan objects of up to 16
keys and binary-search a sorted key index above that; arrays of containers with 16+
elements get an offset table, so `arr[i]` is O(1).

**Nesting.** Parsing, serialization, copying, conversion and destruction are all
iterative, so depth never exhausts the stack. `max_depth` (default 512) is a policy limit
on parsed input; raise it if you need deeper documents.

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

**Performance.** Parsing writes one contiguous block of 16-byte values and one string
arena: no allocation per value. On parsed documents `get()`/`[]` return views; on
`JsonValue` they deep-copy. Number conversion uses the standard fast algorithms: Clinger's fast path and
**Eisel-Lemire** (as in fast_float, Rust, Go) for parsing, with an exact big-integer
fallback for the rare undecidable cases, and **Schubfach** (as in Java 19+) for printing.
`pixi run bench` reports parse/serialize throughput.

## Security

`parse_json` is designed for untrusted input:

- **No crashes.** Fuzzed with 1M+ mutated documents (with stdlib bounds checks on),
  checking every document's internal layout invariants; every input either parses or
  raises. Every unchecked pointer read is preceded by a bounds check or grammar
  validation.
- **No recursion.** Parsing, serialization, copy, conversion and destruction are
  iterative, for parsed documents and built `JsonValue` trees alike (tested at 1M levels).
- **Bounded memory.** A parsed document takes 16 bytes per value plus its strings: at
  most ~8x the input size for the worst case (inputs made only of tiny values like
  `[0,0,…]` or `[{},{},…]`), ~3x for typical documents.
- **Bounded work per byte.** Parsing is linear or O(n log n) in the input. Even crafted
  ~800-digit floats sitting exactly between two doubles parse at ~90 MB/s.
- **No hash flooding.** Parsed objects use a sorted key index (no hashing). Built
  `JsonValue` objects hash keys with a per-object random seed.
- **Safe error messages.** Errors never echo raw control or non-ASCII bytes from the
  input (they are shown as hex), so they are safe to log.

Callers should still cap input size before parsing, and may lower `max_depth` if they
don't expect deep documents.

## Development

```bash
pixi run test          # unit tests
pixi run conformance   # JSONTestSuite (clones it into .cache/ on first run)
pixi run fuzz          # number parse/print differential fuzz against CPython
pixi run fuzz-parser   # mutated-document differential fuzz against CPython json
pixi run bench         # parse/serialize throughput
pixi run memprobe      # memory used by parsing, relative to input size
pixi run gen-tables    # regenerate the float tables in json.mojo (--check in CI)
pixi run format        # mojo format
```

`conformance`, `fuzz`, and `fuzz-parser` need `python3` on the PATH. CI runs all of
them on Linux and macOS.

## License

MIT — see [LICENSE](LICENSE).
