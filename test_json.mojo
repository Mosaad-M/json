# ============================================================================
# test_json.mojo — Tests for JSON Parser
# ============================================================================

from json import JsonValue, parse_json


# ============================================================================
# Test Helpers
# ============================================================================


fn assert_true(cond: Bool, label: String) raises:
    if not cond:
        raise Error(label + ": expected True, got False")


fn assert_false(cond: Bool, label: String) raises:
    if cond:
        raise Error(label + ": expected False, got True")


fn assert_int_eq(actual: Int, expected: Int, label: String) raises:
    if actual != expected:
        raise Error(
            label + ": expected " + String(expected) + ", got " + String(actual)
        )


fn assert_str_eq(actual: String, expected: String, label: String) raises:
    if actual != expected:
        raise Error(
            label + ": expected '" + expected + "', got '" + actual + "'"
        )


fn assert_float_near(
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


# ============================================================================
# Primitive Tests
# ============================================================================


fn test_null() raises:
    var v = parse_json("null")
    assert_true(v.is_null(), "is_null")


fn test_true() raises:
    var v = parse_json("true")
    assert_true(v.is_bool(), "is_bool")
    assert_true(v.as_bool(), "value")


fn test_false() raises:
    var v = parse_json("false")
    assert_true(v.is_bool(), "is_bool")
    assert_false(v.as_bool(), "value")


fn test_integer() raises:
    var v = parse_json("42")
    assert_true(v.is_number(), "is_number")
    assert_int_eq(v.as_int(), 42, "as_int")


fn test_negative_number() raises:
    var v = parse_json("-7")
    assert_int_eq(v.as_int(), -7, "as_int")


fn test_decimal_number() raises:
    var v = parse_json("3.14")
    assert_float_near(v.as_number(), 3.14, 0.001, "as_number")


fn test_exponent_number() raises:
    var v = parse_json("1e3")
    assert_float_near(v.as_number(), 1000.0, 0.1, "exponent")


fn test_string() raises:
    var v = parse_json('"hello"')
    assert_true(v.is_string(), "is_string")
    assert_str_eq(v.as_string(), "hello", "value")


fn test_empty_string() raises:
    var v = parse_json('""')
    assert_str_eq(v.as_string(), "", "empty string")


fn test_string_with_escapes() raises:
    var v = parse_json('"line1\\nline2\\ttab"')
    assert_str_eq(v.as_string(), "line1\nline2\ttab", "escapes")


# ============================================================================
# Compound Tests
# ============================================================================


fn test_empty_array() raises:
    var v = parse_json("[]")
    assert_true(v.is_array(), "is_array")
    assert_int_eq(len(v), 0, "len")


fn test_number_array() raises:
    var v = parse_json("[1, 2, 3]")
    assert_int_eq(len(v), 3, "len")
    assert_int_eq(v.get(0).as_int(), 1, "arr[0]")
    assert_int_eq(v.get(1).as_int(), 2, "arr[1]")
    assert_int_eq(v.get(2).as_int(), 3, "arr[2]")


fn test_empty_object() raises:
    var v = parse_json("{}")
    assert_true(v.is_object(), "is_object")
    var k = v.keys()
    assert_int_eq(len(k), 0, "keys len")


fn test_simple_object() raises:
    var v = parse_json('{"name": "Alice", "age": 30}')
    assert_str_eq(v.get("name").as_string(), "Alice", "name")
    assert_int_eq(v.get("age").as_int(), 30, "age")
    assert_true(v.has_key("name"), "has_key name")
    assert_false(v.has_key("missing"), "has_key missing")


# ============================================================================
# Nested Tests
# ============================================================================


fn test_nested_objects() raises:
    var v = parse_json('{"user": {"first": "Bob", "last": "Smith"}}')
    var user = v.get("user")
    assert_str_eq(user.get("first").as_string(), "Bob", "first")
    assert_str_eq(user.get("last").as_string(), "Smith", "last")


fn test_array_of_objects() raises:
    var v = parse_json('[{"id": 1}, {"id": 2}]')
    assert_int_eq(len(v), 2, "len")
    assert_int_eq(v.get(0).get("id").as_int(), 1, "arr[0].id")
    assert_int_eq(v.get(1).get("id").as_int(), 2, "arr[1].id")


fn test_object_with_array() raises:
    var v = parse_json('{"tags": ["a", "b", "c"]}')
    var tags = v.get("tags")
    assert_int_eq(len(tags), 3, "tags len")
    assert_str_eq(tags.get(0).as_string(), "a", "tags[0]")
    assert_str_eq(tags.get(2).as_string(), "c", "tags[2]")


# ============================================================================
# Whitespace & Edge Cases
# ============================================================================


fn test_extra_whitespace() raises:
    var v = parse_json('  {  "x" :  1  ,  "y"  :  2  }  ')
    assert_int_eq(v.get("x").as_int(), 1, "x")
    assert_int_eq(v.get("y").as_int(), 2, "y")


# ============================================================================
# Error Cases
# ============================================================================


fn test_empty_input_raises() raises:
    var raised = False
    try:
        _ = parse_json("")
    except:
        raised = True
    assert_true(raised, "empty input should raise")


fn test_invalid_input_raises() raises:
    var raised = False
    try:
        _ = parse_json("xyz")
    except:
        raised = True
    assert_true(raised, "invalid input should raise")


fn test_unterminated_string_raises() raises:
    var raised = False
    try:
        _ = parse_json('"hello')
    except:
        raised = True
    assert_true(raised, "unterminated string should raise")


# ============================================================================
# Pythonic API Tests
# ============================================================================


fn test_print_null() raises:
    assert_str_eq(String(parse_json("null")), "null", "print null")


fn test_print_number() raises:
    assert_str_eq(String(parse_json("42")), "42", "print int")
    var s = String(parse_json("3.14"))
    # Float rendering may vary; just check it contains 3.14
    assert_true(s.find("3.14") >= 0, "print float contains 3.14")


fn test_print_string() raises:
    assert_str_eq(String(parse_json('"hello"')), '"hello"', "print string")


fn test_print_array() raises:
    assert_str_eq(String(parse_json("[1, 2]")), "[1, 2]", "print array")


fn test_print_object() raises:
    var s = String(parse_json('{"a": 1}'))
    assert_true(s.find('"a"') >= 0, "print obj has key a")
    assert_true(s.find("1") >= 0, "print obj has value 1")


fn test_subscript_access() raises:
    var arr = parse_json("[10, 20, 30]")
    assert_int_eq(arr[0].as_int(), 10, "arr[0]")
    assert_int_eq(arr[2].as_int(), 30, "arr[2]")

    var obj = parse_json('{"x": 5, "y": 9}')
    assert_int_eq(obj["x"].as_int(), 5, 'obj["x"]')
    assert_int_eq(obj["y"].as_int(), 9, 'obj["y"]')


fn test_contains() raises:
    var obj = parse_json('{"name": "Alice", "age": 30}')
    assert_true("name" in obj, "contains name")
    assert_true("age" in obj, "contains age")
    assert_false("missing" in obj, "not contains missing")

    # Non-object should return False
    var arr = parse_json("[1, 2]")
    assert_false("x" in arr, "contains on array")


fn test_bool_truthiness() raises:
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


fn test_len_object() raises:
    var obj = parse_json('{"a": 1, "b": 2, "c": 3}')
    assert_int_eq(len(obj), 3, "object len")

    var empty = parse_json("{}")
    assert_int_eq(len(empty), 0, "empty object len")


# ============================================================================
# API Response Simulation
# ============================================================================


fn test_api_response() raises:
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


fn test_leaf_get_string() raises:
    var v = parse_json('{"name": "Alice", "city": "NYC"}')
    assert_str_eq(v.get_string("name"), "Alice", "get_string name")
    assert_str_eq(v.get_string("city"), "NYC", "get_string city")


fn test_leaf_get_int() raises:
    var v = parse_json('{"age": 30, "score": -5}')
    assert_int_eq(v.get_int("age"), 30, "get_int age")
    assert_int_eq(v.get_int("score"), -5, "get_int score")


fn test_leaf_get_number() raises:
    var v = parse_json('{"pi": 3.14, "count": 42}')
    assert_float_near(v.get_number("pi"), 3.14, 0.001, "get_number pi")
    assert_float_near(v.get_number("count"), 42.0, 0.001, "get_number count")


fn test_leaf_get_bool() raises:
    var v = parse_json('{"active": true, "deleted": false}')
    assert_true(v.get_bool("active"), "get_bool active")
    assert_false(v.get_bool("deleted"), "get_bool deleted")


fn test_leaf_array_accessors() raises:
    var v = parse_json('["hello", 42, true, 3.14]')
    assert_str_eq(v.get_string(0), "hello", "arr get_string")
    assert_int_eq(v.get_int(1), 42, "arr get_int")
    assert_true(v.get_bool(2), "arr get_bool")
    assert_float_near(v.get_number(3), 3.14, 0.001, "arr get_number")


fn test_leaf_get_array_len() raises:
    var v = parse_json('{"tags": ["a", "b", "c"], "empty": []}')
    assert_int_eq(v.get_array_len("tags"), 3, "get_array_len tags")
    assert_int_eq(v.get_array_len("empty"), 0, "get_array_len empty")


fn test_leaf_type_mismatch_raises() raises:
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


fn test_leaf_missing_key_raises() raises:
    var v = parse_json('{"x": 1}')
    var raised = False
    try:
        _ = v.get_string("missing")
    except:
        raised = True
    assert_true(raised, "get_string missing key should raise")


# ============================================================================
# Test Runner
# ============================================================================


fn main() raises:
    var passed = 0
    var failed = 0

    fn run_test(
        name: String,
        mut passed: Int,
        mut failed: Int,
        test_fn: fn () raises -> None,
    ):
        try:
            test_fn()
            print("  PASS:", name)
            passed += 1
        except e:
            print("  FAIL:", name, "-", String(e))
            failed += 1

    print("=== JSON Parser Tests ===")
    print()

    # Primitives
    run_test("null", passed, failed, test_null)
    run_test("true", passed, failed, test_true)
    run_test("false", passed, failed, test_false)
    run_test("integer", passed, failed, test_integer)
    run_test("negative number", passed, failed, test_negative_number)
    run_test("decimal number", passed, failed, test_decimal_number)
    run_test("exponent number", passed, failed, test_exponent_number)
    run_test("string", passed, failed, test_string)
    run_test("empty string", passed, failed, test_empty_string)
    run_test("string with escapes", passed, failed, test_string_with_escapes)

    # Compounds
    run_test("empty array", passed, failed, test_empty_array)
    run_test("number array", passed, failed, test_number_array)
    run_test("empty object", passed, failed, test_empty_object)
    run_test("simple object", passed, failed, test_simple_object)

    # Nested
    run_test("nested objects", passed, failed, test_nested_objects)
    run_test("array of objects", passed, failed, test_array_of_objects)
    run_test("object with array", passed, failed, test_object_with_array)

    # Whitespace
    run_test("extra whitespace", passed, failed, test_extra_whitespace)

    # Pythonic API
    run_test("print null", passed, failed, test_print_null)
    run_test("print number", passed, failed, test_print_number)
    run_test("print string", passed, failed, test_print_string)
    run_test("print array", passed, failed, test_print_array)
    run_test("print object", passed, failed, test_print_object)
    run_test("subscript access", passed, failed, test_subscript_access)
    run_test("contains", passed, failed, test_contains)
    run_test("bool truthiness", passed, failed, test_bool_truthiness)
    run_test("len object", passed, failed, test_len_object)

    # Errors
    run_test("empty input raises", passed, failed, test_empty_input_raises)
    run_test("invalid input raises", passed, failed, test_invalid_input_raises)
    run_test(
        "unterminated string raises",
        passed,
        failed,
        test_unterminated_string_raises,
    )

    # API simulation
    run_test("api response", passed, failed, test_api_response)

    # Leaf accessors
    run_test("leaf get_string", passed, failed, test_leaf_get_string)
    run_test("leaf get_int", passed, failed, test_leaf_get_int)
    run_test("leaf get_number", passed, failed, test_leaf_get_number)
    run_test("leaf get_bool", passed, failed, test_leaf_get_bool)
    run_test("leaf array accessors", passed, failed, test_leaf_array_accessors)
    run_test("leaf get_array_len", passed, failed, test_leaf_get_array_len)
    run_test(
        "leaf type mismatch raises",
        passed,
        failed,
        test_leaf_type_mismatch_raises,
    )
    run_test(
        "leaf missing key raises",
        passed,
        failed,
        test_leaf_missing_key_raises,
    )

    print()
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
