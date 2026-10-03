# ============================================================================
# test_json.mojo — Tests for JSON Parser
# ============================================================================

from std.memory import bitcast

from json import (
    _eisel_lemire,
    JSON_OBJECT,
    JsonValue,
    parse_json,
    json_null,
    json_bool,
    json_number,
    json_int,
    json_string,
    json_array,
    json_object,
)


# ============================================================================
# Test Helpers
# ============================================================================


def assert_true(cond: Bool, label: String) raises:
    if not cond:
        raise Error(label + ": expected True, got False")


def assert_false(cond: Bool, label: String) raises:
    if cond:
        raise Error(label + ": expected False, got True")


def assert_int_eq(actual: Int, expected: Int, label: String) raises:
    if actual != expected:
        raise Error(
            label + ": expected " + String(expected) + ", got " + String(actual)
        )


def assert_str_eq(actual: String, expected: String, label: String) raises:
    if actual != expected:
        raise Error(
            label + ": expected '" + expected + "', got '" + actual + "'"
        )


def assert_float_near(
    actual: Float64, expected: Float64, tol: Float64, label: String
) raises:
    var diff = actual - expected
    if diff < 0:
        diff = -diff
    if diff > tol:
        raise Error(
            label
            + ": expected ~"
            + String(expected)
            + ", got "
            + String(actual)
        )


def assert_float_eq(actual: Float64, expected: Float64, label: String) raises:
    if actual != expected:
        raise Error(
            label + ": expected " + String(expected) + ", got " + String(actual)
        )


def _clip(s: String) -> String:
    if s.byte_length() <= 40:
        return s
    return String(s[byte=0:40]) + "..."


def assert_rejects(s: String, label: String) raises:
    var accepted = False
    try:
        _ = parse_json(s)
        accepted = True
    except:
        pass
    if accepted:
        raise Error(label + ": expected parse error for " + _clip(s))


def assert_accepts(s: String, label: String) raises:
    try:
        _ = parse_json(s)
    except e:
        raise Error(
            label + ": unexpected error for " + _clip(s) + ": " + String(e)
        )


def _nested(depth: Int) -> String:
    var s = String()
    for _ in range(depth):
        s += "["
    for _ in range(depth):
        s += "]"
    return s^


# ============================================================================
# Primitive Tests
# ============================================================================


def test_null() raises:
    var v = parse_json("null")
    assert_true(v.is_null(), "is_null")


def test_true() raises:
    var v = parse_json("true")
    assert_true(v.is_bool(), "is_bool")
    assert_true(v.as_bool(), "value")


def test_false() raises:
    var v = parse_json("false")
    assert_true(v.is_bool(), "is_bool")
    assert_false(v.as_bool(), "value")


def test_integer() raises:
    var v = parse_json("42")
    assert_true(v.is_number(), "is_number")
    assert_int_eq(v.as_int(), 42, "as_int")


def test_negative_number() raises:
    var v = parse_json("-7")
    assert_int_eq(v.as_int(), -7, "as_int")


def test_decimal_number() raises:
    var v = parse_json("3.14")
    assert_float_near(v.as_number(), 3.14, 0.001, "as_number")


def test_exponent_number() raises:
    var v = parse_json("1e3")
    assert_float_near(v.as_number(), 1000.0, 0.1, "exponent")


def test_string() raises:
    var v = parse_json('"hello"')
    assert_true(v.is_string(), "is_string")
    assert_str_eq(v.as_string(), "hello", "value")


def test_empty_string() raises:
    var v = parse_json('""')
    assert_str_eq(v.as_string(), "", "empty string")


def test_string_with_escapes() raises:
    var v = parse_json('"line1\\nline2\\ttab"')
    assert_str_eq(v.as_string(), "line1\nline2\ttab", "escapes")


# ============================================================================
# Compound Tests
# ============================================================================


def test_empty_array() raises:
    var v = parse_json("[]")
    assert_true(v.is_array(), "is_array")
    assert_int_eq(len(v), 0, "len")


def test_number_array() raises:
    var v = parse_json("[1, 2, 3]")
    assert_int_eq(len(v), 3, "len")
    assert_int_eq(v.get(0).as_int(), 1, "arr[0]")
    assert_int_eq(v.get(1).as_int(), 2, "arr[1]")
    assert_int_eq(v.get(2).as_int(), 3, "arr[2]")


def test_empty_object() raises:
    var v = parse_json("{}")
    assert_true(v.is_object(), "is_object")
    var k = v.keys()
    assert_int_eq(len(k), 0, "keys len")


def test_simple_object() raises:
    var v = parse_json('{"name": "Alice", "age": 30}')
    assert_str_eq(v.get("name").as_string(), "Alice", "name")
    assert_int_eq(v.get("age").as_int(), 30, "age")
    assert_true(v.has_key("name"), "has_key name")
    assert_false(v.has_key("missing"), "has_key missing")


# ============================================================================
# Nested Tests
# ============================================================================


def test_nested_objects() raises:
    var v = parse_json('{"user": {"first": "Bob", "last": "Smith"}}')
    var user = v.get("user")
    assert_str_eq(user.get("first").as_string(), "Bob", "first")
    assert_str_eq(user.get("last").as_string(), "Smith", "last")


def test_array_of_objects() raises:
    var v = parse_json('[{"id": 1}, {"id": 2}]')
    assert_int_eq(len(v), 2, "len")
    assert_int_eq(v.get(0).get("id").as_int(), 1, "arr[0].id")
    assert_int_eq(v.get(1).get("id").as_int(), 2, "arr[1].id")


def test_object_with_array() raises:
    var v = parse_json('{"tags": ["a", "b", "c"]}')
    var tags = v.get("tags")
    assert_int_eq(len(tags), 3, "tags len")
    assert_str_eq(tags.get(0).as_string(), "a", "tags[0]")
    assert_str_eq(tags.get(2).as_string(), "c", "tags[2]")


# ============================================================================
# Whitespace & Edge Cases
# ============================================================================


def test_extra_whitespace() raises:
    var v = parse_json('  {  "x" :  1  ,  "y"  :  2  }  ')
    assert_int_eq(v.get("x").as_int(), 1, "x")
    assert_int_eq(v.get("y").as_int(), 2, "y")


# ============================================================================
# Error Cases
# ============================================================================


def test_empty_input_raises() raises:
    var raised = False
    try:
        _ = parse_json("")
    except:
        raised = True
    assert_true(raised, "empty input should raise")


def test_invalid_input_raises() raises:
    var raised = False
    try:
        _ = parse_json("xyz")
    except:
        raised = True
    assert_true(raised, "invalid input should raise")


def test_unterminated_string_raises() raises:
    var raised = False
    try:
        _ = parse_json('"hello')
    except:
        raised = True
    assert_true(raised, "unterminated string should raise")


# ============================================================================
# Pythonic API Tests
# ============================================================================


def test_print_null() raises:
    assert_str_eq(String(parse_json("null")), "null", "print null")


def test_print_number() raises:
    assert_str_eq(String(parse_json("42")), "42", "print int")
    var s = String(parse_json("3.14"))
    # Float rendering may vary; just check it contains 3.14
    assert_true(s.find("3.14") >= 0, "print float contains 3.14")


def test_print_string() raises:
    assert_str_eq(String(parse_json('"hello"')), '"hello"', "print string")


def test_print_array() raises:
    assert_str_eq(String(parse_json("[1, 2]")), "[1, 2]", "print array")


def test_print_object() raises:
    var s = String(parse_json('{"a": 1}'))
    assert_true(s.find('"a"') >= 0, "print obj has key a")
    assert_true(s.find("1") >= 0, "print obj has value 1")


def test_subscript_access() raises:
    var arr = parse_json("[10, 20, 30]")
    assert_int_eq(arr[0].as_int(), 10, "arr[0]")
    assert_int_eq(arr[2].as_int(), 30, "arr[2]")

    var obj = parse_json('{"x": 5, "y": 9}')
    assert_int_eq(obj["x"].as_int(), 5, 'obj["x"]')
    assert_int_eq(obj["y"].as_int(), 9, 'obj["y"]')


def test_contains() raises:
    var obj = parse_json('{"name": "Alice", "age": 30}')
    assert_true("name" in obj, "contains name")
    assert_true("age" in obj, "contains age")
    assert_false("missing" in obj, "not contains missing")

    # Non-object should return False
    var arr = parse_json("[1, 2]")
    assert_false("x" in arr, "contains on array")


def test_bool_truthiness() raises:
    # null is falsy
    assert_false(Bool(parse_json("null")), "null is falsy")
    # true/false
    assert_true(Bool(parse_json("true")), "true is truthy")
    assert_false(Bool(parse_json("false")), "false is falsy")
    # numbers
    assert_true(Bool(parse_json("42")), "42 is truthy")
    assert_false(Bool(parse_json("0")), "0 is falsy")
    # strings
    assert_true(Bool(parse_json('"hi"')), "non-empty string truthy")
    assert_false(Bool(parse_json('""')), "empty string falsy")
    # arrays
    assert_true(Bool(parse_json("[1]")), "non-empty array truthy")
    assert_false(Bool(parse_json("[]")), "empty array falsy")
    # objects
    assert_true(Bool(parse_json('{"a": 1}')), "non-empty object truthy")
    assert_false(Bool(parse_json("{}")), "empty object falsy")


def test_len_object() raises:
    var obj = parse_json('{"a": 1, "b": 2, "c": 3}')
    assert_int_eq(len(obj), 3, "object len")

    var empty = parse_json("{}")
    assert_int_eq(len(empty), 0, "empty object len")


# ============================================================================
# API Response Simulation
# ============================================================================


def test_api_response() raises:
    """Simulate parsing a response body like httpbin.org /get."""
    var body = String(
        '{"url": "https://httpbin.org/get", "args": {},'
        ' "headers": {"Host": "httpbin.org", "Accept": "*/*"},'
        ' "origin": "1.2.3.4"}'
    )
    var v = parse_json(body)
    assert_str_eq(v.get("url").as_string(), "https://httpbin.org/get", "url")
    assert_str_eq(v.get("origin").as_string(), "1.2.3.4", "origin")
    var headers = v.get("headers")
    assert_str_eq(headers.get("Host").as_string(), "httpbin.org", "Host")


# ============================================================================
# Leaf Accessor Tests
# ============================================================================


def test_leaf_get_string() raises:
    var v = parse_json('{"name": "Alice", "city": "NYC"}')
    assert_str_eq(v.get_string("name"), "Alice", "get_string name")
    assert_str_eq(v.get_string("city"), "NYC", "get_string city")


def test_leaf_get_int() raises:
    var v = parse_json('{"age": 30, "score": -5}')
    assert_int_eq(v.get_int("age"), 30, "get_int age")
    assert_int_eq(v.get_int("score"), -5, "get_int score")


def test_leaf_get_number() raises:
    var v = parse_json('{"pi": 3.14, "count": 42}')
    assert_float_near(v.get_number("pi"), 3.14, 0.001, "get_number pi")
    assert_float_near(v.get_number("count"), 42.0, 0.001, "get_number count")


def test_leaf_get_bool() raises:
    var v = parse_json('{"active": true, "deleted": false}')
    assert_true(v.get_bool("active"), "get_bool active")
    assert_false(v.get_bool("deleted"), "get_bool deleted")


def test_leaf_array_accessors() raises:
    var v = parse_json('["hello", 42, true, 3.14]')
    assert_str_eq(v.get_string(0), "hello", "arr get_string")
    assert_int_eq(v.get_int(1), 42, "arr get_int")
    assert_true(v.get_bool(2), "arr get_bool")
    assert_float_near(v.get_number(3), 3.14, 0.001, "arr get_number")


def test_leaf_get_array_len() raises:
    var v = parse_json('{"tags": ["a", "b", "c"], "empty": []}')
    assert_int_eq(v.get_array_len("tags"), 3, "get_array_len tags")
    assert_int_eq(v.get_array_len("empty"), 0, "get_array_len empty")


def test_leaf_type_mismatch_raises() raises:
    var v = parse_json('{"name": "Alice", "age": 30}')
    var raised = False
    try:
        _ = v.get_int("name")  # name is a string, not int
    except:
        raised = True
    assert_true(raised, "get_int on string should raise")

    raised = False
    try:
        _ = v.get_string("age")  # age is a number, not string
    except:
        raised = True
    assert_true(raised, "get_string on number should raise")


def test_leaf_missing_key_raises() raises:
    var v = parse_json('{"x": 1}')
    var raised = False
    try:
        _ = v.get_string("missing")
    except:
        raised = True
    assert_true(raised, "get_string missing key should raise")


# ============================================================================
# RFC 8259 Strictness
# ============================================================================


def test_reject_malformed_numbers() raises:
    assert_rejects("01", "leading zero")
    assert_rejects("-01", "negative leading zero")
    assert_rejects("[01]", "leading zero in array")
    assert_rejects("1.", "no fraction digits")
    assert_rejects("1.e5", "no fraction digits before exponent")
    assert_rejects("1e", "no exponent digits")
    assert_rejects("1e+", "no exponent digits after sign")
    assert_rejects("-", "bare minus")
    assert_rejects(".5", "no integer part")
    assert_rejects("+1", "leading plus")


def test_accept_valid_numbers() raises:
    assert_accepts("0", "zero")
    assert_accepts("-0", "negative zero")
    assert_accepts("0.5", "zero fraction")
    assert_accepts("1E+2", "upper exponent")
    assert_accepts("1e-2", "negative exponent")
    assert_accepts("-12.5e3", "full grammar")


def test_reject_bad_strings() raises:
    assert_rejects('"\\x"', "unknown escape")
    assert_rejects('"\\u12"', "short \\u escape")
    assert_rejects('"\\uZZZZ"', "non-hex \\u escape")
    assert_rejects('"a\tb"', "raw tab in string")
    assert_rejects('"a\nb"', "raw newline in string")
    assert_rejects('"\\ud800"', "lone high surrogate")
    assert_rejects('"\\udc00"', "lone low surrogate")
    assert_rejects('"\\ud800\\u0041"', "high surrogate + non-low")


def test_reject_structural_errors() raises:
    assert_rejects("[1,]", "trailing comma in array")
    assert_rejects('{"a":1,}', "trailing comma in object")
    assert_rejects("[1 2]", "missing comma")
    assert_rejects("{1:2}", "non-string key")
    assert_rejects("tru", "truncated literal")
    assert_rejects("nul", "truncated null")
    assert_rejects("[] []", "two top-level values")


# ============================================================================
# Unicode
# ============================================================================


def test_unicode_escape_bmp() raises:
    assert_str_eq(parse_json('"\\u00e9"').as_string(), "é", "\\u00e9")
    assert_str_eq(parse_json('"\\u20AC"').as_string(), "€", "\\u20AC")
    assert_str_eq(parse_json('"\\u0041"').as_string(), "A", "\\u0041")


def test_unicode_surrogate_pair() raises:
    assert_str_eq(
        parse_json('"\\ud83d\\ude00"').as_string(), "😀", "surrogate pair"
    )


def test_unicode_raw_utf8() raises:
    var v = parse_json('{"k": "héllo €"}')
    assert_str_eq(v.get_string("k"), "héllo €", "raw utf-8")


def test_string_len_is_codepoints() raises:
    assert_int_eq(len(parse_json('"héllo"')), 5, "len of héllo")


# ============================================================================
# Number Precision
# ============================================================================


def test_large_integer_no_overflow() raises:
    var v = parse_json("12345678901234567890123")
    assert_float_eq(v.as_number(), 1.2345678901234568e22, "big int")
    assert_float_eq(
        parse_json("9223372036854775807").as_number(),
        9.223372036854775807e18,
        "int64 max",
    )


def test_int_limits() raises:
    assert_int_eq(
        parse_json("123456789012345678").as_int(),
        123456789012345678,
        "18-digit int exact",
    )
    assert_int_eq(parse_json("-42").as_int(), -42, "negative int")
    var raised = False
    try:
        _ = parse_json("1e30").as_int()
    except:
        raised = True
    assert_true(raised, "as_int out of range should raise")


def test_float_correctly_rounded() raises:
    assert_float_eq(parse_json("0.1").as_number(), 0.1, "0.1")
    assert_float_eq(parse_json("3.14").as_number(), 3.14, "3.14")
    assert_float_eq(
        parse_json("1.7976931348623157e308").as_number(),
        1.7976931348623157e308,
        "float64 max",
    )
    assert_float_eq(
        parse_json("2.2250738585072014e-308").as_number(),
        2.2250738585072014e-308,
        "float64 min normal",
    )
    assert_float_eq(
        parse_json("123.456e-7").as_number(), 123.456e-7, "scaled exponent"
    )
    assert_true(parse_json("5e-324").as_number() > 0.0, "min subnormal")


def test_float_long_mantissa() raises:
    assert_float_eq(
        parse_json(
            "0.1000000000000000055511151231257827021181583404541015625"
        ).as_number(),
        0.1,
        "exact decimal of 0.1",
    )
    assert_float_eq(
        parse_json("123456789012345678901234567890.5").as_number(),
        1.2345678901234568e29,
        "30-digit mantissa",
    )
    var one = String("1")
    for _ in range(400):
        one += "0"
    one += "e-400"
    assert_float_eq(parse_json(one).as_number(), 1.0, "401 digits e-400")
    assert_float_eq(
        parse_json("99999999999999999999").as_number(), 1e20, "carry"
    )


def test_float_19_digit_small_exponent() raises:
    # 19-digit mantissa / 10^k once took a negative shift in the 128-bit path
    assert_float_eq(
        parse_json("9553080861940584321e-1").as_number(),
        9.553080861940584321e17,
        "19 digits e-1",
    )
    assert_float_eq(
        parse_json("-6968826931977303.326e2").as_number(),
        -6.968826931977303326e17,
        "19 digits, fraction",
    )
    assert_float_eq(
        parse_json("1.080906649651967441e+17").as_number(),
        1.080906649651967441e17,
        "19 digits e+17",
    )


def test_float_edge_values() raises:
    assert_float_eq(parse_json("0.005").as_number(), 0.005, "leading zeros")
    assert_float_eq(parse_json("100e-2").as_number(), 1.0, "trailing zeros")
    assert_float_eq(parse_json("1e-400").as_number(), 0.0, "underflow to 0")
    assert_float_eq(parse_json("1E+2").as_number(), 100.0, "upper E")
    assert_true(parse_json("-0").as_number() == 0.0, "-0 is zero")
    assert_true(parse_json("1.0").is_number(), "1.0 is number")
    assert_false(parse_json("1.0").is_int(), "1.0 is not int")
    assert_true(parse_json("1").is_int(), "1 is int")


def test_int64_boundaries() raises:
    assert_int_eq(
        parse_json("9223372036854775807").as_int(), Int.MAX, "Int.MAX exact"
    )
    assert_int_eq(
        parse_json("-9223372036854775808").as_int(), Int.MIN, "Int.MIN"
    )
    assert_false(
        parse_json("9223372036854775808").is_int(), "Int.MAX+1 is float"
    )


def test_reject_number_overflow() raises:
    assert_rejects("1e400", "overflows to inf")
    assert_rejects("-1e400", "overflows to -inf")


# ============================================================================
# Nesting Depth
# ============================================================================


def test_depth_limit() raises:
    assert_accepts(_nested(500), "depth 500")
    assert_rejects(_nested(10000), "depth 10000")
    var raised = False
    try:
        _ = parse_json(_nested(5), max_depth=4)
    except:
        raised = True
    assert_true(raised, "custom max_depth")
    _ = parse_json(_nested(4), max_depth=4)


# ============================================================================
# Serialization
# ============================================================================


def test_serialize_non_finite_as_null() raises:
    var inf = Float64.MAX * 2.0
    assert_str_eq(String(json_number(inf)), "null", "inf")
    assert_str_eq(String(json_number(-inf)), "null", "-inf")
    assert_str_eq(String(json_number(inf - inf)), "null", "nan")


def test_serialize_large_numbers() raises:
    var s = String(json_number(1e300))
    assert_float_eq(parse_json(s).as_number(), 1e300, "1e300 round-trip")
    assert_str_eq(
        String(json_number(9007199254740992.0)), "9007199254740992.0", "2^53"
    )
    # Mojo 1.0's float formatter prints this with one digit too few
    var x = 3.8323297207132664e16
    assert_float_eq(parse_json(String(json_number(x))).as_number(), x, "2^55")
    var y = -6.3845019134348795e19  # also misformatted, above 2^63
    assert_float_eq(parse_json(String(json_number(y))).as_number(), y, "2^65")
    assert_float_eq(
        parse_json(String(json_number(1.7976931348623157e308))).as_number(),
        1.7976931348623157e308,
        "float64 max",
    )
    assert_str_eq(String(json_number(-0.0)), "-0.0", "negative zero")
    assert_str_eq(String(json_number(2.5)), "2.5", "fraction")


def test_serialize_escapes_round_trip() raises:
    var src = '"quote\\" back\\\\ nl\\n tab\\t ctl\\u0001 é"'
    var v = parse_json(src)
    var again = parse_json(String(v))
    assert_str_eq(again.as_string(), v.as_string(), "escape round-trip")


def test_round_trip_document() raises:
    var src = String(
        '{"a": [1, 2.5, -3, true, false, null], "b": {"c": "d"}, "e": []}'
    )
    assert_str_eq(String(parse_json(src)), src, "document round-trip")


# ============================================================================
# Building / Mutation
# ============================================================================


def test_build_array() raises:
    var arr = json_array()
    arr.append(json_int(1))
    arr.append(json_string("two"))
    arr.append(json_null())
    assert_int_eq(len(arr), 3, "len")
    assert_str_eq(String(arr), '[1, "two", null]', "serialized")


def test_build_object() raises:
    var obj = json_object()
    obj.set("name", json_string("mojo"))
    obj.set("ok", json_bool(True))
    obj.set("name", json_string("json"))
    assert_int_eq(len(obj), 2, "overwrite keeps len")
    assert_str_eq(String(obj), '{"name": "json", "ok": true}', "serialized")


def test_build_nested() raises:
    var inner = json_array()
    inner.append(json_number(1))
    var obj = json_object()
    obj.set("xs", inner^)
    assert_int_eq(obj.get_array_len("xs"), 1, "nested array len")


def test_mutation_type_errors() raises:
    var raised = False
    try:
        var v = json_object()
        v.append(json_null())
    except:
        raised = True
    assert_true(raised, "append on object should raise")
    raised = False
    try:
        var v = json_array()
        v.set("k", json_null())
    except:
        raised = True
    assert_true(raised, "set on array should raise")


# ============================================================================
# Objects
# ============================================================================


def test_duplicate_keys_last_wins() raises:
    var v = parse_json('{"b": 1, "a": 2, "b": 3}')
    var k = v.keys()
    assert_int_eq(len(k), 2, "dedup len")
    assert_str_eq(k[0], "b", "first key keeps position")
    assert_str_eq(k[1], "a", "second key")
    assert_int_eq(v.get_int("b"), 3, "last value wins")


def test_large_object() raises:
    var n = 2000
    var s = String("{")
    for i in range(n):
        if i > 0:
            s += ", "
        s += '"k' + String(i) + '": ' + String(i)
    s += "}"
    var v = parse_json(s)
    assert_int_eq(len(v), n, "len")
    assert_int_eq(v.get_int("k0"), 0, "first")
    assert_int_eq(v.get_int("k1999"), 1999, "last")
    assert_int_eq(v["k1000"].as_int(), 1000, "middle via subscript")
    assert_true("k1500" in v, "contains")
    assert_false("k2000" in v, "not contains")
    var k = v.keys()
    assert_str_eq(k[1234], "k1234", "insertion order")


# ============================================================================
# Float algorithms: exact expectations generated by CPython
# ============================================================================


def check_parse_bits(text: String, expected: Int) raises:
    var got = Int(bitcast[DType.int64](parse_json(text).as_number()))
    if got != expected:
        raise Error(
            text
            + ": expected bits "
            + String(expected)
            + ", got "
            + String(got)
        )


def check_repr(bits: UInt64, expected: String) raises:
    var got = String(json_number(bitcast[DType.float64](bits)))
    if got != expected:
        raise Error(
            "bits " + String(bits) + ": expected " + expected + ", got " + got
        )


def check_el(w: UInt64, q: Int, expected: Int, must_decide: Bool) raises:
    var got = Int(_eisel_lemire(w, q))
    if got == -1 and not must_decide:
        return  # allowed to defer to the exact slow path
    if got != expected:
        raise Error(
            "eisel_lemire("
            + String(w)
            + ", "
            + String(q)
            + "): expected "
            + String(expected)
            + ", got "
            + String(got)
        )


def test_float_hard_parse_cases() raises:
    # Classic traps (exact ties, subnormal boundaries, max/overflow edges,
    # the Java/PHP 2.2250738585072012e-308 hang); bits from CPython.
    check_parse_bits("2.2250738585072012e-308", 4503599627370496)
    check_parse_bits("2.2250738585072011e-308", 4503599627370495)
    check_parse_bits("2.2250738585072014e-308", 4503599627370496)
    check_parse_bits("2.2250738585072009e-308", 4503599627370495)
    check_parse_bits("4.9406564584124654e-324", 1)
    check_parse_bits("2.4703282292062327e-324", 0)
    check_parse_bits("2.4703282292062328e-324", 1)
    check_parse_bits("1.7976931348623157e308", 9218868437227405311)
    check_parse_bits("1.7976931348623158e308", 9218868437227405311)
    check_parse_bits("1e23", 4950912855330343670)
    check_parse_bits("8.98846567431158e307", 9214364837600034816)
    check_parse_bits("7.2057594037927933e16", 4859383997932765184)
    check_parse_bits("9007199254740993.0", 4845873199050653696)
    check_parse_bits("9007199254740993.5", 4845873199050653697)
    check_parse_bits("9007199254740995.0", 4845873199050653698)
    check_parse_bits(
        "1.00000000000000011102230246251565404236316680908203125",
        4607182418800017408,
    )
    check_parse_bits(
        "1.00000000000000011102230246251565404236316680908203124",
        4607182418800017408,
    )
    check_parse_bits(
        "1.00000000000000011102230246251565404236316680908203126",
        4607182418800017409,
    )
    check_parse_bits("9553080861940584321e-1", 4875854541610897258)
    check_parse_bits("-6968826931977303.326e2", -4349536443626662364)
    check_parse_bits("0.1", 4591870180066957722)
    check_parse_bits("0.3", 4599075939470750515)
    check_parse_bits("123456789012345678901234567890e-30", 4593560419847042655)
    check_parse_bits("45035996.273704985", 4721313438954982461)
    check_parse_bits("1.448997445238699", 4609204523527084717)
    check_parse_bits("4.35679e-10", 4466990888571413152)
    check_parse_bits("1e-323", 2)
    check_parse_bits("5e-324", 1)
    check_parse_bits("2.4e-324", 0)
    check_parse_bits("1e308", 9214871658872686752)
    check_parse_bits("9.9999999999999999e22", 4950912855330343670)
    check_parse_bits("1.2345678901234567e-300", 120036974821017864)
    check_parse_bits("17976931348623157e292", 9218868437227405311)
    check_parse_bits("-0.0", -9223372036854775808)
    check_parse_bits("-2.2250738585072012e-308", -9218868437227405312)
    check_parse_bits("3.0540412E5", 4688990415295170478)
    check_parse_bits("2.5E-1", 4598175219545276416)


def test_float_overflow_boundary() raises:
    assert_rejects("1.7976931348623159e308", "rounds to inf")
    assert_rejects("17976931348623159e292", "rounds to inf, long form")


def test_float_repr_output() raises:
    # Shortest round-trip digits in CPython repr format, byte for byte.
    check_repr(4591870180066957722, "0.1")
    check_repr(4599676419421066581, "0.3333333333333333")
    check_repr(1, "5e-324")
    check_repr(2, "1e-323")
    check_repr(12, "6e-323")
    check_repr(20, "1e-322")
    check_repr(13, "6.4e-323")
    check_repr(4503599627370496, "2.2250738585072014e-308")
    check_repr(9218868437227405311, "1.7976931348623157e+308")
    check_repr(4831355200913801216, "1000000000000000.0")
    check_repr(4846369599423283200, "1e+16")
    check_repr(4547007122018943789, "0.0001")
    check_repr(4532020583610935537, "1e-05")
    check_repr(4636737291354636288, "100.0")
    check_repr(9223372036854775808, "-0.0")
    check_repr(0, "0.0")
    check_repr(4845873199050653696, "9007199254740992.0")
    check_repr(4855167210828915775, "3.8323297207132664e+16")
    check_repr(14126578413243803397, "-6.3845019134348796e+19")
    check_repr(4862596447618666293, "1.2345678901234568e+17")
    check_repr(4607182418800017408, "1.0")
    check_repr(13832806255468478464, "-1.5")
    check_repr(4638387860618067575, "123.456")
    check_repr(4936209963552724370, "1e+22")
    check_repr(4921056587992461136, "1e+21")
    check_repr(4502148214488346440, "1e-07")
    check_repr(4537999922764202797, "2.5e-05")
    check_repr(6103021453049119613, "1e+100")
    check_repr(101201126653655, "5e-310")
    check_repr(4832797072101665536, "1234567890123456.0")
    check_repr(4847542438873900484, "1.2345678901234568e+16")
    check_repr(4548669923058963014, "0.000123")
    check_repr(4890909195324358656, "9.223372036854776e+18")
    check_repr(4466990888571413152, "4.35679e-10")
    check_repr(4733809291562057728, "299792458.0")
    check_repr(4517110426252607488, "9.5367431640625e-07")


def test_eisel_lemire_decides_typical() raises:
    # Typical 15-19 digit mantissas must take the fast path; if they fell
    # back to the slow path everything would stay correct but ~10x slower.
    check_el(934911684991697, -5, 4756199236650882548, True)
    check_el(2256845828445918, -27, 4432626113332252341, True)
    check_el(6446332115853614978, 14, 5098013661852912087, True)
    check_el(205488819735150, -13, 4626477213757054050, True)
    check_el(6422501460899537, -37, 4289752820625179445, True)
    check_el(7604115266222097961, 29, 5323437557777928338, True)
    check_el(617902765409618912, -5, 4798157327840002242, True)
    check_el(886035535474372, 14, 5040060912307067533, True)
    check_el(32406957245830025, -13, 4659344780336248330, True)
    check_el(23366084693029869, 8, 4971671334224284952, True)
    check_el(779735886445425, -7, 4725005128440218355, True)
    check_el(617267520467920, 28, 5247176213580446237, True)
    check_el(188718470258963, 30, 5269471888341082949, True)
    check_el(62117099670721217, -16, 4618679782100647805, True)
    check_el(844515597706649, -11, 4665868387926046656, True)
    check_el(21499238000654924, -11, 4686627094766084010, True)
    check_el(412971604521943, 18, 5094798711226868674, True)
    check_el(63348700015276777, 5, 4932979395161551992, True)
    check_el(3404725002639780, -31, 4375397241258514523, True)
    check_el(2578475388236853219, 28, 5301318307859839856, True)
    check_el(5163666552602351, 8, 4961654052872706326, True)
    check_el(41649882684277305, 1, 4870395391729554009, True)
    check_el(551668705642492, -6, 4737910940883893550, True)
    check_el(738588377270244, 0, 4829263907931963168, True)
    check_el(5496674660209685, 10, 4991883758994601752, True)
    check_el(405386043808627587, -23, 4526399979544740455, True)
    check_el(6056356528134425, 28, 5261816122444569225, True)
    check_el(94247719454723078, 14, 5070416860217001173, True)
    check_el(4338827910277438615, -12, 4706416791969201229, True)
    check_el(5445194555510952, -29, 4408645091124290773, True)
    check_el(223453943397782, -21, 4507537879045259396, True)
    check_el(7129230970992268, 14, 5053600805560320498, True)
    check_el(4548852045832477200, 8, 5005615037316984293, True)
    check_el(5316998219059023769, 27, 5291111106961882626, True)
    check_el(89728255180511161, -39, 4277045682510357782, True)
    check_el(945415078880052, -6, 4741213924860405131, True)
    check_el(52297826252599017, 15, 5081363005130897132, True)
    check_el(1029229201177763, -7, 4726679449732946522, True)
    check_el(2647772770547790958, 24, 5241738182247652871, True)
    check_el(804026188074518, -2, 4800063231688090808, True)


def test_eisel_lemire_extremes() raises:
    # Range edges: must be exact when the fast path decides.
    check_el(1, -342, 0, False)
    check_el(4940656458412465, -339, 1, False)
    check_el(17976931348623157, 292, 9218868437227405311, False)
    check_el(1, 308, 9214871658872686752, False)
    check_el(9007199254740993, 0, 4845873199050653696, False)
    check_el(2470328229206232720, -342, 0, False)
    check_el(2470328229206232721, -342, 1, False)


# ============================================================================
# Flat documents (JsonDoc / JsonRef)
# ============================================================================


def test_doc_iteration() raises:
    var doc = parse_json(
        '{"a": [10, "x", null, [1]], "b": {"c": true}, "d": 2.5}'
    )
    var names = List[String]()
    for m in doc.entries():
        names.append(m.key())
    assert_int_eq(len(names), 3, "entries count")
    assert_str_eq(names[0], "a", "first key")
    assert_str_eq(names[1], "b", "second key")
    assert_str_eq(names[2], "d", "third key")
    var parts = String()
    for v in doc["a"].items():
        parts += String(v) + ";"
    assert_str_eq(parts, '10;"x";null;[1];', "items in order")
    for m in doc.entries():
        if m.key() == "b":
            assert_true(m.value.get_bool("c"), "member value view")


def test_doc_views_no_copy() raises:
    var doc = parse_json('{"user": {"name": "Ada", "tags": ["x", "y"]}}')
    var user = doc["user"]  # a view, not a copy
    assert_str_eq(user.get_string("name"), "Ada", "nested view")
    assert_str_eq(String(user["tags"][1]), '"y"', "chained views")
    assert_str_eq(
        String(user["name"].as_string_slice()), "Ada", "zero-copy slice"
    )
    assert_int_eq(user.kind(), JSON_OBJECT, "kind()")


def _big_object_text() -> String:
    # >= 16 keys (sorted index): shared prefixes, empty key, escapes,
    # non-ASCII, and a key that sorts last
    var keys = List[String]()
    keys.append("")
    keys.append("a")
    keys.append("aa")
    keys.append("ab")
    keys.append("a\\u0000")
    keys.append("é")
    keys.append("\\ud83d\\ude00")
    keys.append("zz")
    for i in range(20):
        keys.append("k" + String(i))
    var s = String("{")
    for i in range(len(keys)):
        if i > 0:
            s += ", "
        s += '"' + keys[i] + '": ' + String(i)
    return s + "}"


def test_large_object_lookup_edges() raises:
    var doc = parse_json(_big_object_text())
    doc._validate()
    assert_int_eq(len(doc), 28, "len")
    assert_int_eq(doc.get_int(""), 0, "empty key")
    assert_int_eq(doc.get_int("a"), 1, "prefix a")
    assert_int_eq(doc.get_int("aa"), 2, "prefix aa")
    assert_int_eq(doc.get_int("ab"), 3, "prefix ab")
    assert_int_eq(doc.get_int("a\x00"), 4, "embedded NUL key")
    assert_int_eq(doc.get_int("é"), 5, "non-ASCII key")
    assert_int_eq(doc.get_int("😀"), 6, "astral key")
    assert_int_eq(doc.get_int("zz"), 7, "last in sort order")
    assert_int_eq(doc.get_int("k19"), 27, "k19")
    assert_false("" + "b" in doc, "missing between keys")
    assert_false("zzz" in doc, "missing after last")
    assert_false("A" in doc, "missing before first non-empty")
    var k = doc.keys()
    assert_str_eq(k[3], "ab", "keys() keeps document order")


def test_duplicate_keys_compaction() raises:
    # Small object, and large (indexed) object with nested duplicate values
    var small = parse_json('{"a": 1, "b": [1, {"x": 1}], "a": {"y": [2]}}')
    small._validate()
    assert_str_eq(
        String(small), '{"a": {"y": [2]}, "b": [1, {"x": 1}]}', "small"
    )
    var s = String("{")
    for i in range(20):
        s += '"k' + String(i) + '": ' + String(i) + ", "
    s += '"k3": [1, {"deep": [1, 2]}], "k0": {"z": null}, "k3": {"w": [3]}}'
    var big = parse_json(s)
    big._validate()
    assert_int_eq(len(big), 20, "unique count")
    assert_str_eq(String(big["k3"]), '{"w": [3]}', "last value wins")
    assert_str_eq(String(big["k0"]), '{"z": null}', "last value wins (k0)")
    assert_str_eq(big.keys()[0], "k0", "first position kept")
    assert_int_eq(big.get_int("k19"), 19, "other keys intact")


def test_array_random_access() raises:
    var s = String("[")
    for i in range(1000):
        if i > 0:
            s += ","
        s += '{"i": ' + String(i) + "}"
    s += "]"
    var doc = parse_json(s)
    doc._validate()
    assert_true(doc._slots[0].index_start() >= 0, "offset table built")
    assert_int_eq(doc[0].get_int("i"), 0, "first")
    assert_int_eq(doc[500].get_int("i"), 500, "middle")
    assert_int_eq(doc[999].get_int("i"), 999, "last")
    var raised = False
    try:
        _ = doc[1000]
    except:
        raised = True
    assert_true(raised, "out of range raises")
    var flat = parse_json("[" + String("7,") * 99 + "7]")
    assert_true(doc._slots[0].index_start() >= 0, "objects: indexed")
    assert_true(flat._slots[0].index_start() < 0, "scalars: no table needed")
    assert_int_eq(flat.get_int(99), 7, "flat stride access")


def test_parse_very_deep() raises:
    var depth = 100_000
    var doc = parse_json(_nested(depth), max_depth=depth)
    doc._validate()
    assert_int_eq(String(doc).byte_length(), 2 * depth, "round trip")
    var tree = doc.to_value()  # iterative conversion
    assert_int_eq(String(tree).byte_length(), 2 * depth, "tree round trip")
    var copy = tree.copy()  # iterative copy; both destroyed iteratively
    assert_true(copy.is_array(), "deep copy")


def test_build_very_deep_value() raises:
    var root = json_array()
    for _ in range(1_000_000):
        var outer = json_array()
        outer.append(root^)
        root = outer^
    var copy = root.copy()
    assert_int_eq(String(copy).byte_length(), 2_000_002, "deep print")
    # root and copy are destroyed here, iteratively


def test_to_value_is_mutable_copy() raises:
    var doc = parse_json('{"a": [1, 2], "b": "x"}')
    var v = doc.to_value()
    v.set("c", json_int(3))
    assert_str_eq(String(v), '{"a": [1, 2], "b": "x", "c": 3}', "mutated tree")
    assert_str_eq(String(doc), '{"a": [1, 2], "b": "x"}', "doc unchanged")


def test_build_large_object_seeded_index() raises:
    var obj = json_object()
    for i in range(200):
        obj.set("k" + String(i), json_int(i))
    obj.set("k7", json_int(-7))
    assert_int_eq(len(obj), 200, "overwrite keeps len")
    assert_int_eq(obj.get_int("k7"), -7, "overwrite via index")
    assert_int_eq(obj.get_int("k199"), 199, "lookup via index")
    assert_false("k200" in obj, "missing key")
    var c = obj.copy()
    assert_int_eq(c.get_int("k150"), 150, "copied index works")


# ============================================================================
# Test Runner
# ============================================================================


def run_test[
    test_fn: def() thin raises -> None
](name: String, mut passed: Int, mut failed: Int):
    try:
        test_fn()
        print("  PASS:", name)
        passed += 1
    except e:
        print("  FAIL:", name, "-", String(e))
        failed += 1


def main() raises:
    var passed = 0
    var failed = 0

    print("=== JSON Parser Tests ===")
    print()

    # Primitives
    run_test[test_null]("null", passed, failed)
    run_test[test_true]("true", passed, failed)
    run_test[test_false]("false", passed, failed)
    run_test[test_integer]("integer", passed, failed)
    run_test[test_negative_number]("negative number", passed, failed)
    run_test[test_decimal_number]("decimal number", passed, failed)
    run_test[test_exponent_number]("exponent number", passed, failed)
    run_test[test_string]("string", passed, failed)
    run_test[test_empty_string]("empty string", passed, failed)
    run_test[test_string_with_escapes]("string with escapes", passed, failed)

    # Compounds
    run_test[test_empty_array]("empty array", passed, failed)
    run_test[test_number_array]("number array", passed, failed)
    run_test[test_empty_object]("empty object", passed, failed)
    run_test[test_simple_object]("simple object", passed, failed)

    # Nested
    run_test[test_nested_objects]("nested objects", passed, failed)
    run_test[test_array_of_objects]("array of objects", passed, failed)
    run_test[test_object_with_array]("object with array", passed, failed)

    # Whitespace
    run_test[test_extra_whitespace]("extra whitespace", passed, failed)

    # Pythonic API
    run_test[test_print_null]("print null", passed, failed)
    run_test[test_print_number]("print number", passed, failed)
    run_test[test_print_string]("print string", passed, failed)
    run_test[test_print_array]("print array", passed, failed)
    run_test[test_print_object]("print object", passed, failed)
    run_test[test_subscript_access]("subscript access", passed, failed)
    run_test[test_contains]("contains", passed, failed)
    run_test[test_bool_truthiness]("bool truthiness", passed, failed)
    run_test[test_len_object]("len object", passed, failed)

    # Errors
    run_test[test_empty_input_raises]("empty input raises", passed, failed)
    run_test[test_invalid_input_raises]("invalid input raises", passed, failed)
    run_test[test_unterminated_string_raises](
        "unterminated string raises", passed, failed
    )

    # API simulation
    run_test[test_api_response]("api response", passed, failed)

    # Leaf accessors
    run_test[test_leaf_get_string]("leaf get_string", passed, failed)
    run_test[test_leaf_get_int]("leaf get_int", passed, failed)
    run_test[test_leaf_get_number]("leaf get_number", passed, failed)
    run_test[test_leaf_get_bool]("leaf get_bool", passed, failed)
    run_test[test_leaf_array_accessors]("leaf array accessors", passed, failed)
    run_test[test_leaf_get_array_len]("leaf get_array_len", passed, failed)
    run_test[test_leaf_type_mismatch_raises](
        "leaf type mismatch raises", passed, failed
    )
    run_test[test_leaf_missing_key_raises](
        "leaf missing key raises", passed, failed
    )

    # RFC 8259 strictness
    run_test[test_reject_malformed_numbers](
        "reject malformed numbers", passed, failed
    )
    run_test[test_accept_valid_numbers]("accept valid numbers", passed, failed)
    run_test[test_reject_bad_strings]("reject bad strings", passed, failed)
    run_test[test_reject_structural_errors](
        "reject structural errors", passed, failed
    )

    # Unicode
    run_test[test_unicode_escape_bmp]("unicode escape BMP", passed, failed)
    run_test[test_unicode_surrogate_pair](
        "unicode surrogate pair", passed, failed
    )
    run_test[test_unicode_raw_utf8]("unicode raw utf-8", passed, failed)
    run_test[test_string_len_is_codepoints](
        "string len is codepoints", passed, failed
    )

    # Number precision
    run_test[test_large_integer_no_overflow](
        "large integer no overflow", passed, failed
    )
    run_test[test_int_limits]("int limits", passed, failed)
    run_test[test_float_correctly_rounded](
        "float correctly rounded", passed, failed
    )
    run_test[test_float_long_mantissa]("float long mantissa", passed, failed)
    run_test[test_float_19_digit_small_exponent](
        "float 19-digit small exponent", passed, failed
    )
    run_test[test_float_edge_values]("float edge values", passed, failed)
    run_test[test_int64_boundaries]("int64 boundaries", passed, failed)
    run_test[test_float_hard_parse_cases](
        "float hard parse cases", passed, failed
    )
    run_test[test_float_overflow_boundary](
        "float overflow boundary", passed, failed
    )
    run_test[test_float_repr_output]("float repr output", passed, failed)
    run_test[test_eisel_lemire_decides_typical](
        "eisel-lemire decides typical", passed, failed
    )
    run_test[test_eisel_lemire_extremes](
        "eisel-lemire extremes", passed, failed
    )
    run_test[test_reject_number_overflow](
        "reject number overflow", passed, failed
    )

    # Nesting depth
    run_test[test_depth_limit]("depth limit", passed, failed)

    # Serialization
    run_test[test_serialize_non_finite_as_null](
        "serialize non-finite as null", passed, failed
    )
    run_test[test_serialize_large_numbers](
        "serialize large numbers", passed, failed
    )
    run_test[test_serialize_escapes_round_trip](
        "serialize escapes round-trip", passed, failed
    )
    run_test[test_round_trip_document]("round-trip document", passed, failed)

    # Building / mutation
    run_test[test_build_array]("build array", passed, failed)
    run_test[test_build_object]("build object", passed, failed)
    run_test[test_build_nested]("build nested", passed, failed)
    run_test[test_mutation_type_errors]("mutation type errors", passed, failed)

    # Objects
    run_test[test_duplicate_keys_last_wins](
        "duplicate keys last wins", passed, failed
    )
    run_test[test_large_object]("large object", passed, failed)

    # Flat documents
    run_test[test_doc_iteration]("doc iteration", passed, failed)
    run_test[test_doc_views_no_copy]("doc views (no copy)", passed, failed)
    run_test[test_large_object_lookup_edges](
        "large object lookup edges", passed, failed
    )
    run_test[test_duplicate_keys_compaction](
        "duplicate keys compaction", passed, failed
    )
    run_test[test_array_random_access]("array random access", passed, failed)
    run_test[test_parse_very_deep]("parse 100k-deep", passed, failed)
    run_test[test_build_very_deep_value]("build 1M-deep value", passed, failed)
    run_test[test_to_value_is_mutable_copy](
        "to_value mutable copy", passed, failed
    )
    run_test[test_build_large_object_seeded_index](
        "built object seeded index", passed, failed
    )

    print()
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
