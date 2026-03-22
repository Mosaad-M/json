# ============================================================================
# json.mojo — JSON Parser
# ============================================================================
#
# Recursive descent JSON parser producing a JsonValue tree.
# Supports: null, bool, number, string, array, object.
#
# Usage:
#   var val = parse_json('{"key": 42}')
#   var n = val.get("key").as_int()
#
# ============================================================================

from std.memory.unsafe_pointer import UnsafePointer, alloc


# ============================================================================
# Type Tags
# ============================================================================

comptime JSON_NULL = 0
comptime JSON_BOOL = 1
comptime JSON_NUMBER = 2
comptime JSON_STRING = 3
comptime JSON_ARRAY = 4
comptime JSON_OBJECT = 5

# ============================================================================
# Byte Constants — avoid repeated ord() calls
# ============================================================================

comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))
comptime _SLASH = UInt8(ord("/"))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))
comptime _COLON = UInt8(ord(":"))
comptime _COMMA = UInt8(ord(","))
comptime _DOT = UInt8(ord("."))
comptime _MINUS = UInt8(ord("-"))
comptime _PLUS = UInt8(ord("+"))
comptime _SPACE = UInt8(ord(" "))
comptime _TAB = UInt8(ord("\t"))
comptime _CR = UInt8(ord("\r"))
comptime _LF = UInt8(ord("\n"))
comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _LOWER_A = UInt8(ord("a"))
comptime _LOWER_E = UInt8(ord("e"))
comptime _LOWER_F = UInt8(ord("f"))
comptime _LOWER_L = UInt8(ord("l"))
comptime _LOWER_N = UInt8(ord("n"))
comptime _LOWER_R = UInt8(ord("r"))
comptime _LOWER_S = UInt8(ord("s"))
comptime _LOWER_T = UInt8(ord("t"))
comptime _LOWER_U = UInt8(ord("u"))
comptime _UPPER_E = UInt8(ord("E"))
comptime _QUESTION = UInt8(ord("?"))
comptime _BACKSPACE = UInt8(8)
comptime _FORMFEED = UInt8(12)


# ============================================================================
# String Escaping Helper
# ============================================================================


def _write_escaped_string[W: Writer](s: String, mut writer: W):
    """Escape a string for JSON output (without surrounding quotes).

    Batches consecutive non-escape bytes into a single write to avoid
    per-byte chr() calls. For strings with no escape characters (the
    common case), writes the original string directly — zero copy.
    """
    var total = len(s)
    if total == 0:
        return
    var s_copy = s
    var ptr = s_copy.as_c_string_slice().unsafe_ptr().bitcast[UInt8]()
    var run_start = 0
    for i in range(total):
        var c = (ptr + i)[]
        if c == _QUOTE or c == _BACKSLASH or c < 0x20:
            # Flush the non-escape run before this escape char
            if i > run_start:
                var run = List[UInt8](capacity=i - run_start)
                for j in range(run_start, i):
                    run.append((ptr + j)[])
                writer.write(String(unsafe_from_utf8=run^))
            # Write the escape sequence
            if c == _QUOTE:
                writer.write('\\"')
            elif c == _BACKSLASH:
                writer.write("\\\\")
            elif c == _LF:
                writer.write("\\n")
            elif c == _CR:
                writer.write("\\r")
            elif c == _TAB:
                writer.write("\\t")
            else:
                # Other control chars: \u00XX
                writer.write("\\u00")
                var hi = Int(c) >> 4
                var lo = Int(c) & 0x0F
                if hi < 10:
                    writer.write(chr(Int(_ZERO) + hi))
                else:
                    writer.write(chr(Int(_LOWER_A) + hi - 10))
                if lo < 10:
                    writer.write(chr(Int(_ZERO) + lo))
                else:
                    writer.write(chr(Int(_LOWER_A) + lo - 10))
            run_start = i + 1
    # Flush remaining run
    if run_start == 0:
        # No escapes at all — write original string directly (zero copy)
        writer.write(s)
    elif run_start < total:
        var run = List[UInt8](capacity=total - run_start)
        for j in range(run_start, total):
            run.append((ptr + j)[])
        writer.write(String(unsafe_from_utf8=run^))


# ============================================================================
# JsonObject — Key/Value Storage (parallel lists)
# ============================================================================


struct JsonObject(Copyable, Movable, Sized, Writable):
    """JSON object stored as parallel lists of keys and values."""

    var _keys: List[String]
    var _values: List[JsonValue]

    def __init__(out self, capacity: Int = 4):
        self._keys = List[String](capacity=capacity)
        self._values = List[JsonValue](capacity=capacity)

    def __copyinit__(out self, copy: Self):
        self._keys = copy._keys.copy()
        self._values = copy._values.copy()

    def __moveinit__(out self, deinit take: Self):
        self._keys = take._keys^
        self._values = take._values^

    def set(mut self, key: String, var value: JsonValue):
        """Set a key-value pair. Overwrites if key exists."""
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                self._values[i] = value^
                return
        self._keys.append(key)
        self._values.append(value^)

    def get(self, key: String) raises -> JsonValue:
        """Get value by key. Raises if key not found."""
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return self._values[i].copy()
        raise Error("JSON key not found: " + key)

    def has_key(self, key: String) -> Bool:
        """Check if key exists."""
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return True
        return False

    def keys(self) -> List[String]:
        """Return a copy of the keys list."""
        return self._keys.copy()

    def __len__(self) -> Int:
        return len(self._keys)

    def write_to[W: Writer](self, mut writer: W):
        """Serialize as JSON object string."""
        writer.write("{")
        for i in range(len(self._keys)):
            if i > 0:
                writer.write(", ")
            writer.write('"')
            _write_escaped_string[W](self._keys[i], writer)
            writer.write('": ')
            self._values[i].write_to(writer)
        writer.write("}")

    def __str__(self) -> String:
        return String.write(self)


# ============================================================================
# JsonValue — Tagged Union
# ============================================================================


struct JsonValue(
    Boolable, Copyable, Movable, SizedRaising, Writable
):
    """A JSON value: null, bool, number, string, array, or object.

    Uses UnsafePointer for recursive types (array, object) to break
    circular dependency and allow heap allocation.
    """

    var kind: Int
    var _bool_val: Bool
    var _num_val: Float64
    var _str_val: String
    var _arr_ptr: UnsafePointer[List[JsonValue], MutAnyOrigin]
    var _obj_ptr: UnsafePointer[JsonObject, MutAnyOrigin]

    def __init__(out self):
        """Create a null JsonValue."""
        self.kind = JSON_NULL
        self._bool_val = False
        self._num_val = 0.0
        self._str_val = String("")
        self._arr_ptr = UnsafePointer[List[JsonValue], MutAnyOrigin]()
        self._obj_ptr = UnsafePointer[JsonObject, MutAnyOrigin]()

    def __copyinit__(out self, copy: Self):
        self.kind = copy.kind
        self._bool_val = copy._bool_val
        self._num_val = copy._num_val
        self._str_val = copy._str_val
        # Deep copy heap-allocated data
        if copy._arr_ptr:
            self._arr_ptr = alloc[List[JsonValue]](1)
            self._arr_ptr.init_pointee_copy(copy._arr_ptr[])
        else:
            self._arr_ptr = UnsafePointer[List[JsonValue], MutAnyOrigin]()
        if copy._obj_ptr:
            self._obj_ptr = alloc[JsonObject](1)
            self._obj_ptr.init_pointee_copy(copy._obj_ptr[])
        else:
            self._obj_ptr = UnsafePointer[JsonObject, MutAnyOrigin]()

    def __moveinit__(out self, deinit take: Self):
        self.kind = take.kind
        self._bool_val = take._bool_val
        self._num_val = take._num_val
        self._str_val = take._str_val^
        self._arr_ptr = take._arr_ptr
        self._obj_ptr = take._obj_ptr

    def __del__(deinit self):
        if self._arr_ptr:
            self._arr_ptr.destroy_pointee()
            self._arr_ptr.free()
        if self._obj_ptr:
            self._obj_ptr.destroy_pointee()
            self._obj_ptr.free()

    def copy(self) -> Self:
        """Explicit deep copy."""
        var v = Self()
        v.kind = self.kind
        v._bool_val = self._bool_val
        v._num_val = self._num_val
        v._str_val = self._str_val
        if self._arr_ptr:
            v._arr_ptr = alloc[List[JsonValue]](1)
            v._arr_ptr.init_pointee_copy(self._arr_ptr[])
        if self._obj_ptr:
            v._obj_ptr = alloc[JsonObject](1)
            v._obj_ptr.init_pointee_copy(self._obj_ptr[])
        return v^

    # ------------------------------------------------------------------
    # Type checks
    # ------------------------------------------------------------------

    def is_null(self) -> Bool:
        return self.kind == JSON_NULL

    def is_bool(self) -> Bool:
        return self.kind == JSON_BOOL

    def is_number(self) -> Bool:
        return self.kind == JSON_NUMBER

    def is_string(self) -> Bool:
        return self.kind == JSON_STRING

    def is_array(self) -> Bool:
        return self.kind == JSON_ARRAY

    def is_object(self) -> Bool:
        return self.kind == JSON_OBJECT

    # ------------------------------------------------------------------
    # Value accessors
    # ------------------------------------------------------------------

    def as_bool(self) raises -> Bool:
        """Get boolean value. Raises if not a bool."""
        if self.kind != JSON_BOOL:
            raise Error("JsonValue is not a bool")
        return self._bool_val

    def as_number(self) raises -> Float64:
        """Get number value as Float64. Raises if not a number."""
        if self.kind != JSON_NUMBER:
            raise Error("JsonValue is not a number")
        return self._num_val

    def as_int(self) raises -> Int:
        """Get number value as Int. Raises if not a number."""
        if self.kind != JSON_NUMBER:
            raise Error("JsonValue is not a number")
        return Int(self._num_val)

    def as_string(self) raises -> String:
        """Get string value. Raises if not a string."""
        if self.kind != JSON_STRING:
            raise Error("JsonValue is not a string")
        return self._str_val

    # ------------------------------------------------------------------
    # Array accessors
    # ------------------------------------------------------------------

    def get(self, index: Int) raises -> JsonValue:
        """Get array element by index. Raises if not an array."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        var arr_len = len(self._arr_ptr[])
        if index < 0 or index >= arr_len:
            raise Error("array index out of bounds: " + String(index))
        return self._arr_ptr[][index].copy()

    def __len__(self) raises -> Int:
        """Get length. Works for arrays, objects, and strings."""
        if self.kind == JSON_ARRAY:
            if not self._arr_ptr:
                return 0
            return len(self._arr_ptr[])
        elif self.kind == JSON_OBJECT:
            if not self._obj_ptr:
                return 0
            return len(self._obj_ptr[])
        elif self.kind == JSON_STRING:
            return len(self._str_val)
        raise Error("JsonValue of kind " + String(self.kind) + " has no len()")

    # ------------------------------------------------------------------
    # Object accessors
    # ------------------------------------------------------------------

    def get(self, key: String) raises -> JsonValue:
        """Get object value by key. Raises if not an object."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        return self._obj_ptr[].get(key)

    def has_key(self, key: String) raises -> Bool:
        """Check if object has key. Raises if not an object."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            return False
        return self._obj_ptr[].has_key(key)

    def keys(self) raises -> List[String]:
        """Get object keys. Raises if not an object."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            return List[String]()
        return self._obj_ptr[].keys()

    # ------------------------------------------------------------------
    # Leaf accessors — extract primitives without deep-copying the tree
    # ------------------------------------------------------------------

    def get_string(self, key: String) raises -> String:
        """Get string value by key without deep copy."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        for i in range(len(self._obj_ptr[]._keys)):
            if self._obj_ptr[]._keys[i] == key:
                if self._obj_ptr[]._values[i].kind != JSON_STRING:
                    raise Error("value for '" + key + "' is not a string")
                return self._obj_ptr[]._values[i]._str_val
        raise Error("JSON key not found: " + key)

    def get_int(self, key: String) raises -> Int:
        """Get integer value by key without deep copy."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        for i in range(len(self._obj_ptr[]._keys)):
            if self._obj_ptr[]._keys[i] == key:
                if self._obj_ptr[]._values[i].kind != JSON_NUMBER:
                    raise Error("value for '" + key + "' is not a number")
                return Int(self._obj_ptr[]._values[i]._num_val)
        raise Error("JSON key not found: " + key)

    def get_number(self, key: String) raises -> Float64:
        """Get number value by key without deep copy."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        for i in range(len(self._obj_ptr[]._keys)):
            if self._obj_ptr[]._keys[i] == key:
                if self._obj_ptr[]._values[i].kind != JSON_NUMBER:
                    raise Error("value for '" + key + "' is not a number")
                return self._obj_ptr[]._values[i]._num_val
        raise Error("JSON key not found: " + key)

    def get_bool(self, key: String) raises -> Bool:
        """Get boolean value by key without deep copy."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        for i in range(len(self._obj_ptr[]._keys)):
            if self._obj_ptr[]._keys[i] == key:
                if self._obj_ptr[]._values[i].kind != JSON_BOOL:
                    raise Error("value for '" + key + "' is not a bool")
                return self._obj_ptr[]._values[i]._bool_val
        raise Error("JSON key not found: " + key)

    def get_string(self, index: Int) raises -> String:
        """Get string value by array index without deep copy."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        var arr_len = len(self._arr_ptr[])
        if index < 0 or index >= arr_len:
            raise Error("array index out of bounds: " + String(index))
        if self._arr_ptr[][index].kind != JSON_STRING:
            raise Error("value at index " + String(index) + " is not a string")
        return self._arr_ptr[][index]._str_val

    def get_int(self, index: Int) raises -> Int:
        """Get integer value by array index without deep copy."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        var arr_len = len(self._arr_ptr[])
        if index < 0 or index >= arr_len:
            raise Error("array index out of bounds: " + String(index))
        if self._arr_ptr[][index].kind != JSON_NUMBER:
            raise Error("value at index " + String(index) + " is not a number")
        return Int(self._arr_ptr[][index]._num_val)

    def get_number(self, index: Int) raises -> Float64:
        """Get number value by array index without deep copy."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        var arr_len = len(self._arr_ptr[])
        if index < 0 or index >= arr_len:
            raise Error("array index out of bounds: " + String(index))
        if self._arr_ptr[][index].kind != JSON_NUMBER:
            raise Error("value at index " + String(index) + " is not a number")
        return self._arr_ptr[][index]._num_val

    def get_bool(self, index: Int) raises -> Bool:
        """Get boolean value by array index without deep copy."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        var arr_len = len(self._arr_ptr[])
        if index < 0 or index >= arr_len:
            raise Error("array index out of bounds: " + String(index))
        if self._arr_ptr[][index].kind != JSON_BOOL:
            raise Error("value at index " + String(index) + " is not a bool")
        return self._arr_ptr[][index]._bool_val

    def get_array_len(self, key: String) raises -> Int:
        """Get length of a nested array by key without copying it."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        for i in range(len(self._obj_ptr[]._keys)):
            if self._obj_ptr[]._keys[i] == key:
                if self._obj_ptr[]._values[i].kind != JSON_ARRAY:
                    raise Error("value for '" + key + "' is not an array")
                if not self._obj_ptr[]._values[i]._arr_ptr:
                    return 0
                return len(self._obj_ptr[]._values[i]._arr_ptr[])
        raise Error("JSON key not found: " + key)

    # ------------------------------------------------------------------
    # Pythonic API: subscript, contains, bool, print
    # ------------------------------------------------------------------

    def __getitem__(self, key: String) raises -> JsonValue:
        """Subscript access by string key: val["key"]."""
        return self.get(key)

    def __getitem__(self, index: Int) raises -> JsonValue:
        """Subscript access by integer index: val[0]."""
        return self.get(index)

    def __contains__(self, key: String) -> Bool:
        """Check if key exists in object: 'key' in val."""
        if self.kind != JSON_OBJECT:
            return False
        if not self._obj_ptr:
            return False
        return self._obj_ptr[].has_key(key)

    def __bool__(self) -> Bool:
        """Truthiness: null→False, bool→value, number→non-zero, string/array/object→non-empty."""
        if self.kind == JSON_NULL:
            return False
        elif self.kind == JSON_BOOL:
            return self._bool_val
        elif self.kind == JSON_NUMBER:
            return self._num_val != 0.0
        elif self.kind == JSON_STRING:
            return len(self._str_val) > 0
        elif self.kind == JSON_ARRAY:
            if self._arr_ptr:
                return len(self._arr_ptr[]) > 0
            return False
        elif self.kind == JSON_OBJECT:
            if self._obj_ptr:
                return len(self._obj_ptr[]) > 0
            return False
        return False

    def write_to[W: Writer](self, mut writer: W):
        """Serialize as JSON string for print()."""
        if self.kind == JSON_NULL:
            writer.write("null")
        elif self.kind == JSON_BOOL:
            if self._bool_val:
                writer.write("true")
            else:
                writer.write("false")
        elif self.kind == JSON_NUMBER:
            if self._num_val == Float64(Int(self._num_val)):
                writer.write(String(Int(self._num_val)))
            else:
                writer.write(String(self._num_val))
        elif self.kind == JSON_STRING:
            writer.write('"')
            _write_escaped_string[W](self._str_val, writer)
            writer.write('"')
        elif self.kind == JSON_ARRAY:
            writer.write("[")
            if self._arr_ptr:
                var arr_len = len(self._arr_ptr[])
                for i in range(arr_len):
                    if i > 0:
                        writer.write(", ")
                    self._arr_ptr[][i].write_to(writer)
            writer.write("]")
        elif self.kind == JSON_OBJECT:
            if self._obj_ptr:
                self._obj_ptr[].write_to(writer)
            else:
                writer.write("{}")

    def __str__(self) -> String:
        return String.write(self)


# ============================================================================
# Factory Functions
# ============================================================================


def json_null() -> JsonValue:
    """Create a null JsonValue."""
    return JsonValue()


def json_bool(value: Bool) -> JsonValue:
    """Create a boolean JsonValue."""
    var v = JsonValue()
    v.kind = JSON_BOOL
    v._bool_val = value
    return v^


def json_number(value: Float64) -> JsonValue:
    """Create a number JsonValue."""
    var v = JsonValue()
    v.kind = JSON_NUMBER
    v._num_val = value
    return v^


def json_string(value: String) -> JsonValue:
    """Create a string JsonValue."""
    var v = JsonValue()
    v.kind = JSON_STRING
    v._str_val = value
    return v^


def json_array() -> JsonValue:
    """Create an empty array JsonValue."""
    var v = JsonValue()
    v.kind = JSON_ARRAY
    v._arr_ptr = alloc[List[JsonValue]](1)
    v._arr_ptr.init_pointee_move(List[JsonValue](capacity=4))
    return v^


def json_object() -> JsonValue:
    """Create an empty object JsonValue."""
    var v = JsonValue()
    v.kind = JSON_OBJECT
    v._obj_ptr = alloc[JsonObject](1)
    v._obj_ptr.init_pointee_move(JsonObject(capacity=4))
    return v^


# ============================================================================
# Recursive Descent Parser
# ============================================================================


def parse_json(s: String) raises -> JsonValue:
    """Parse a JSON string into a JsonValue tree.

    Args:
        s: JSON string to parse.

    Returns:
        The parsed JsonValue.

    Raises:
        Error if the input is not valid JSON.
    """
    if len(s) == 0:
        raise Error("empty JSON input")
    # Parse directly from the string's memory — no input copy
    var s_copy = String(s)
    var data_ptr = s_copy.as_c_string_slice().unsafe_ptr().bitcast[UInt8]()
    var data_len = len(s)
    var pos: Int = 0
    var result = _parse_value(data_ptr, data_len, pos)
    _skip_whitespace(data_ptr, data_len, pos)
    if pos != data_len:
        raise Error("unexpected trailing content at position " + String(pos))
    return result^


def _skip_whitespace(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
):
    """Skip spaces, tabs, newlines, and carriage returns."""
    while pos < data_len:
        var c = (data_ptr + pos)[]
        if c == _SPACE or c == _TAB or c == _LF or c == _CR:
            pos += 1
        else:
            return


def _parse_value(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> JsonValue:
    """Parse any JSON value starting at pos."""
    _skip_whitespace(data_ptr, data_len, pos)
    if pos >= data_len:
        raise Error("unexpected end of JSON input")

    var c = (data_ptr + pos)[]

    if c == _QUOTE:
        var s = _parse_string(data_ptr, data_len, pos)
        return json_string(s^)
    elif c == _LBRACE:
        return _parse_object(data_ptr, data_len, pos)
    elif c == _LBRACKET:
        return _parse_array(data_ptr, data_len, pos)
    elif c == _LOWER_T:
        _parse_true(data_ptr, data_len, pos)
        return json_bool(True)
    elif c == _LOWER_F:
        _parse_false(data_ptr, data_len, pos)
        return json_bool(False)
    elif c == _LOWER_N:
        _parse_null(data_ptr, data_len, pos)
        return json_null()
    elif c == _MINUS or (c >= _ZERO and c <= _NINE):
        var n = _parse_number(data_ptr, data_len, pos)
        return json_number(n)
    else:
        raise Error(
            "unexpected character '"
            + chr(Int(c))
            + "' at position "
            + String(pos)
        )


def _parse_string(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> String:
    """Parse a JSON string (pos should be at the opening quote)."""
    if (data_ptr + pos)[] != _QUOTE:
        raise Error("expected '\"' at position " + String(pos))
    pos += 1  # skip opening quote

    var result = List[UInt8](capacity=64)
    while pos < data_len:
        var c = (data_ptr + pos)[]
        if c == _QUOTE:
            pos += 1  # skip closing quote
            return String(unsafe_from_utf8=result^)
        elif c == _BACKSLASH:
            pos += 1  # skip backslash
            if pos >= data_len:
                raise Error("unterminated escape sequence")
            var esc = (data_ptr + pos)[]
            if esc == _QUOTE:
                result.append(_QUOTE)
            elif esc == _BACKSLASH:
                result.append(_BACKSLASH)
            elif esc == _SLASH:
                result.append(_SLASH)
            elif esc == _LOWER_N:
                result.append(_LF)
            elif esc == _LOWER_R:
                result.append(_CR)
            elif esc == _LOWER_T:
                result.append(_TAB)
            elif esc == UInt8(ord("b")):
                result.append(_BACKSPACE)
            elif esc == _LOWER_F:
                result.append(_FORMFEED)
            elif esc == _LOWER_U:
                # Skip \uXXXX — emit a replacement character '?'
                pos += 1  # skip 'u'
                # Skip 4 hex digits
                var hex_count = 0
                while hex_count < 4 and pos < data_len:
                    pos += 1
                    hex_count += 1
                result.append(_QUESTION)
                continue  # pos already advanced past hex digits
            else:
                result.append(esc)
            pos += 1
        else:
            result.append(c)
            pos += 1

    raise Error("unterminated string starting at position " + String(pos))


def _parse_number(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> Float64:
    """Parse a JSON number. Uses integer fast path for pure integers."""
    var start = pos
    var is_negative = False
    # Optional minus
    if pos < data_len and (data_ptr + pos)[] == _MINUS:
        is_negative = True
        pos += 1
    # Digits
    if (
        pos >= data_len
        or (data_ptr + pos)[] < _ZERO
        or (data_ptr + pos)[] > _NINE
    ):
        raise Error("invalid number at position " + String(start))
    while (
        pos < data_len
        and (data_ptr + pos)[] >= _ZERO
        and (data_ptr + pos)[] <= _NINE
    ):
        pos += 1
    # Check if this is a pure integer (no '.', 'e', or 'E' follows)
    var is_float = False
    # Fractional part
    if pos < data_len and (data_ptr + pos)[] == _DOT:
        is_float = True
        pos += 1
        while (
            pos < data_len
            and (data_ptr + pos)[] >= _ZERO
            and (data_ptr + pos)[] <= _NINE
        ):
            pos += 1
    # Exponent
    if pos < data_len and (
        (data_ptr + pos)[] == _LOWER_E or (data_ptr + pos)[] == _UPPER_E
    ):
        is_float = True
        pos += 1
        if pos < data_len and (
            (data_ptr + pos)[] == _PLUS or (data_ptr + pos)[] == _MINUS
        ):
            pos += 1
        while (
            pos < data_len
            and (data_ptr + pos)[] >= _ZERO
            and (data_ptr + pos)[] <= _NINE
        ):
            pos += 1

    if not is_float:
        # Integer fast path: multiply-accumulate from digits directly
        var int_start = start
        if is_negative:
            int_start += 1
        var val: Int = 0
        for i in range(int_start, pos):
            val = val * 10 + Int((data_ptr + i)[] - _ZERO)
        if is_negative:
            val = -val
        return Float64(val)

    # Inline float parser — no allocation, pure arithmetic from pointer bytes
    var digit_start = start
    if is_negative:
        digit_start += 1

    # Parse integer + fractional parts as a single mantissa with scale
    var mantissa: Float64 = 0.0
    var frac_scale: Float64 = 1.0
    var past_dot = False
    var fi = digit_start
    while fi < pos:
        var fc = (data_ptr + fi)[]
        if fc == _DOT:
            past_dot = True
            fi += 1
            continue
        if fc == _LOWER_E or fc == _UPPER_E:
            fi += 1
            break
        mantissa = mantissa * 10.0 + Float64(Int(fc - _ZERO))
        if past_dot:
            frac_scale = frac_scale * 10.0
        fi += 1

    var result = mantissa / frac_scale

    # Parse exponent if present
    if fi < pos:
        var exp_negative = False
        if fi < pos and (data_ptr + fi)[] == _PLUS:
            fi += 1
        elif fi < pos and (data_ptr + fi)[] == _MINUS:
            exp_negative = True
            fi += 1
        var exp_val: Int = 0
        while fi < pos:
            exp_val = exp_val * 10 + Int((data_ptr + fi)[] - _ZERO)
            fi += 1
        # Apply exponent via repeated multiply/divide
        var exp_mult: Float64 = 1.0
        for _ in range(exp_val):
            exp_mult *= 10.0
        if exp_negative:
            result = result / exp_mult
        else:
            result = result * exp_mult

    if is_negative:
        result = -result
    return result


def _parse_object(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> JsonValue:
    """Parse a JSON object."""
    if (data_ptr + pos)[] != _LBRACE:
        raise Error("expected '{' at position " + String(pos))
    pos += 1  # skip '{'

    var obj = json_object()

    _skip_whitespace(data_ptr, data_len, pos)
    if pos < data_len and (data_ptr + pos)[] == _RBRACE:
        pos += 1  # empty object
        return obj^

    while True:
        _skip_whitespace(data_ptr, data_len, pos)
        # Parse key
        if pos >= data_len or (data_ptr + pos)[] != _QUOTE:
            raise Error("expected string key at position " + String(pos))
        var key = _parse_string(data_ptr, data_len, pos)

        # Expect colon
        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len or (data_ptr + pos)[] != _COLON:
            raise Error("expected ':' at position " + String(pos))
        pos += 1  # skip ':'

        # Parse value
        var value = _parse_value(data_ptr, data_len, pos)

        # Store in object
        obj._obj_ptr[].set(key^, value^)

        # Expect comma or closing brace
        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len:
            raise Error("unterminated object")
        if (data_ptr + pos)[] == _RBRACE:
            pos += 1
            return obj^
        elif (data_ptr + pos)[] == _COMMA:
            pos += 1
        else:
            raise Error("expected ',' or '}' at position " + String(pos))


def _parse_array(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> JsonValue:
    """Parse a JSON array."""
    if (data_ptr + pos)[] != _LBRACKET:
        raise Error("expected '[' at position " + String(pos))
    pos += 1  # skip '['

    var arr = json_array()

    _skip_whitespace(data_ptr, data_len, pos)
    if pos < data_len and (data_ptr + pos)[] == _RBRACKET:
        pos += 1  # empty array
        return arr^

    while True:
        var value = _parse_value(data_ptr, data_len, pos)
        arr._arr_ptr[].append(value^)

        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len:
            raise Error("unterminated array")
        if (data_ptr + pos)[] == _RBRACKET:
            pos += 1
            return arr^
        elif (data_ptr + pos)[] == _COMMA:
            pos += 1
        else:
            raise Error("expected ',' or ']' at position " + String(pos))


def _parse_true(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises:
    """Parse the literal 'true'."""
    if (
        pos + 3 >= data_len
        or (data_ptr + pos)[] != _LOWER_T
        or (data_ptr + pos + 1)[] != _LOWER_R
        or (data_ptr + pos + 2)[] != _LOWER_U
        or (data_ptr + pos + 3)[] != _LOWER_E
    ):
        raise Error("invalid literal at position " + String(pos))
    pos += 4


def _parse_false(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises:
    """Parse the literal 'false'."""
    if (
        pos + 4 >= data_len
        or (data_ptr + pos)[] != _LOWER_F
        or (data_ptr + pos + 1)[] != _LOWER_A
        or (data_ptr + pos + 2)[] != _LOWER_L
        or (data_ptr + pos + 3)[] != _LOWER_S
        or (data_ptr + pos + 4)[] != _LOWER_E
    ):
        raise Error("invalid literal at position " + String(pos))
    pos += 5


def _parse_null(
    data_ptr: UnsafePointer[UInt8, _], data_len: Int, mut pos: Int
) raises:
    """Parse the literal 'null'."""
    if (
        pos + 3 >= data_len
        or (data_ptr + pos)[] != _LOWER_N
        or (data_ptr + pos + 1)[] != _LOWER_U
        or (data_ptr + pos + 2)[] != _LOWER_L
        or (data_ptr + pos + 3)[] != _LOWER_L
    ):
        raise Error("invalid literal at position " + String(pos))
    pos += 4
