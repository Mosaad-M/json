# json — Pure Mojo JSON Parser

A pure-[Mojo](https://www.modular.com/mojo) recursive descent JSON parser and serializer.

## Features

- Parses all JSON types: `null`, `bool`, `number`, `string`, `array`, `object`
- Clean `JsonValue` tree with typed accessors
- No external dependencies — single file, zero FFI

## Usage

```mojo
from json import parse_json, JsonValue

var val = parse_json('{"name": "mojo", "version": 1, "active": true}')
var name = val.get_string("name")    # "mojo"
var ver  = val.get_int("version")    # 1
var flag = val.get_bool("active")    # True

# Arrays
var arr = parse_json('[1, 2, 3]')
var n = arr.get_int(0)               # 1

# Nested
var nested = parse_json('{"a": {"b": 42}}')
var b = nested.get("a").get_int("b") # 42
```

## Requirements

- Mojo `>=0.26.1`
- No external packages

## Testing

```bash
pixi run test-json
# 39/39 tests pass
```

## License

MIT — see [LICENSE](LICENSE)
