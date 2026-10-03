# Changelog

## 2.0.0

Correctness release. The parser now follows RFC 8259 strictly, so some input that
1.x accepted is now rejected.

### Breaking
- Floats serialize exactly like Python's `repr`: integral floats keep `.0` (`100.0`,
  not `100`), and the exponent form is `1e+16` / `1e-05`. Integers are unchanged.
- Reject malformed numbers: leading zeros (`01`), missing digits (`1.`, `1e`, `-`).
- Reject unknown string escapes (`\x`), raw control characters inside strings, and
  unpaired UTF-16 surrogates.
- Reject numbers that overflow Float64 (`1e400`) instead of returning `inf`.
- `len()` of a string value counts codepoints, not bytes.
- `as_int()` / `get_int()` raise when a float is outside Int64 range (previously
  undefined behavior).

### Fixed
- `\uXXXX` escapes decode to UTF-8, including surrogate pairs (were replaced with `?`).
- Integers longer than 18 digits silently overflowed; now kept exactly up to Int64 and
  converted to the nearest Float64 beyond.
- Float parsing is correctly rounded (Eisel-Lemire with an exact big-integer
  fallback). It no longer uses the stdlib `atof`, which in Mojo 1.0 is not correctly
  rounded and rejects mantissas longer than 19 digits.
- Deeply nested input (e.g. 100,000 `[`) crashed with a stack overflow; nesting is now
  limited by `parse_json(..., max_depth=512)`.
- Float output no longer depends on Mojo's float formatter, which drops a needed
  digit for some large values: floats are printed with Schubfach (shortest round-trip
  digits). `inf`/`nan` are written as `null`.
- The deprecated `alloc` calls were removed, so there are no compiler warnings.

### Security
- Floats with very long mantissas take a bounded-cost exact path (a 40-digit estimate
  plus big-integer comparison against the halfway points) instead of 800-digit decimal
  arithmetic: crafted halfway-case input parses at ~30 MB/s instead of ~3 MB/s.
- Empty arrays/objects no longer pre-allocate, halving memory for inputs like
  `[[],[],…]` / `[{},{},…]` (8.8 MB input: 1.4 GB -> 0.46 GB peak).
- Parse errors never echo raw control or non-ASCII input bytes (shown as hex), so
  error messages are safe to log.

### Added
- `JsonValue.append()` and `JsonValue.set()` for building documents.
- `json_int()` and `JsonValue.is_int()`; integers are stored exactly.
- A hash index for objects with 16 or more keys (lookups were O(n), parsing O(n²)).
- `tools/conformance.py` (JSONTestSuite), `tools/fuzz_floats.py` (number
  parse/print vs CPython), and `tools/fuzz_parser.py` (mutated documents vs CPython's
  `json`), all run in CI.

### Performance (vs 1.1.0, `-O3`, Apple Silicon, `pixi run bench`)
- Serialization: 2.8x faster for mixed documents, 3.6x for floats with ~9 digits,
  5.2x for floats with ~17 digits.
- Objects with many keys: a 20,000-key object parses in 3 ms instead of 447 ms.
- Parsing integers and mixed documents: on par (within ~5%).
- Parsing floats: ~10-25% slower than 1.1.0, which was faster but returned wrong values
  for many inputs; now correctly rounded via a single-pass scanner and Eisel-Lemire.

### Removed
- `mojoproject.toml` (stale; `pixi.toml` is the manifest).

## 1.1.0
- Migrate to Mojo 1.0.0.
- osx-arm64 support and macOS CI.

## 1.0.2
- Qualify stdlib imports with `std.`; drop `Stringable` (Mojo 0.26.2).

## 1.0.1
- Migrate to Mojo 0.26.2 (`fn` → `def`, `UnsafePointer` origins).

## 1.0.0
- Initial release.
