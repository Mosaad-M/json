# ============================================================================
# json.mojo — JSON Parser and Serializer
# ============================================================================
#
# Strict RFC 8259 recursive descent parser producing a JsonValue tree, plus
# a serializer (JsonValue is Writable, so print() / String() emit JSON).
#
# Usage:
#   var val = parse_json('{"key": 42, "tags": ["a", "b"]}')
#   var n = val.get_int("key")        # leaf accessor, no copy
#   var tags = val["tags"]            # subscript, returns a deep copy
#
#   var obj = json_object()
#   obj.set("name", json_string("mojo"))
#   print(obj)                        # {"name": "mojo"}
#
# ============================================================================

from std.bit import count_leading_zeros
from std.builtin.globals import global_constant
from std.collections import Dict
from std.math import isinf, isnan
from std.memory import OwnedPointer, Pointer, bitcast
from std.memory.alloc import unsafe_alloc


# ============================================================================
# Type Tags
# ============================================================================

comptime JSON_NULL = 0
comptime JSON_BOOL = 1
comptime JSON_NUMBER = 2
comptime JSON_STRING = 3
comptime JSON_ARRAY = 4
comptime JSON_OBJECT = 5

comptime DEFAULT_MAX_DEPTH = 512
"""Default nesting limit for parse_json (arrays + objects)."""

# Objects switch from linear key scan to a hash index at this size.
comptime _INDEX_THRESHOLD = 16

# Int64 range as Float64 bounds: [-2^63, 2^63).
comptime _INT_MIN_F = -9223372036854775808.0
comptime _INT_MAX_F = 9223372036854775808.0

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
comptime _LOWER_B = UInt8(ord("b"))
comptime _LOWER_E = UInt8(ord("e"))
comptime _LOWER_F = UInt8(ord("f"))
comptime _LOWER_N = UInt8(ord("n"))
comptime _LOWER_R = UInt8(ord("r"))
comptime _LOWER_T = UInt8(ord("t"))
comptime _LOWER_U = UInt8(ord("u"))
comptime _UPPER_A = UInt8(ord("A"))
comptime _UPPER_E = UInt8(ord("E"))
comptime _UPPER_F = UInt8(ord("F"))
comptime _BACKSPACE = UInt8(8)
comptime _FORMFEED = UInt8(12)


# ============================================================================
# Serialization Helpers
# ============================================================================


def _write_escaped_string[W: Writer](s: String, mut writer: W):
    """Escape a string for JSON output (without surrounding quotes).

    Runs of bytes that need no escaping are written as slices of the
    input, so a string with no escapes is written in a single call.
    """
    var total = s.byte_length()
    var ptr = s.unsafe_ptr()
    var run_start = 0
    for i in range(total):
        var c = ptr[unsafe_offset=i]
        if c != _QUOTE and c != _BACKSLASH and c >= 0x20:
            continue
        if i > run_start:
            writer.write(s[byte=run_start:i])
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
        elif c == _BACKSPACE:
            writer.write("\\b")
        elif c == _FORMFEED:
            writer.write("\\f")
        else:
            # Other control chars: \u00XX
            writer.write("\\u00")
            writer.write(_hex_digit(Int(c) >> 4))
            writer.write(_hex_digit(Int(c) & 0x0F))
        run_start = i + 1
    if run_start < total:
        writer.write(s[byte=run_start:total])


def _hex_digit(n: Int) -> String:
    if n < 10:
        return chr(Int(_ZERO) + n)
    return chr(Int(_LOWER_A) + n - 10)


def _write_float[W: Writer](x: Float64, mut writer: W):
    """Write a Float64 as JSON in CPython repr style.

    Digits are the shortest that round-trip (Schubfach); layout follows
    repr: fixed notation while the decimal point position decpt is in
    (-4, 16] (always with a fractional part, e.g. "100.0"), otherwise
    scientific with a signed, at least two-digit exponent ("1e+16",
    "1e-05"). JSON has no inf/nan, so they are written as null (as
    JavaScript's JSON.stringify does).
    """
    if isnan(x) or isinf(x):
        writer.write("null")
        return
    var bits = bitcast[DType.uint64](x)
    var negative = (bits >> 63) != 0
    if negative:
        writer.write("-")
    if x == 0.0:
        writer.write("0.0")
        return
    var decimal = _shortest_decimal(bits & 0x7FFFFFFFFFFFFFFF)
    var f = decimal[0]
    var e = decimal[1]
    while f % 10 == 0:  # canonical form: no trailing zeros
        f //= 10
        e += 1
    var digits = String(f)
    var n = digits.byte_length()
    var decpt = n + e  # value = 0.<digits> * 10^decpt
    if decpt > -4 and decpt <= 16:
        if decpt <= 0:
            writer.write("0.")
            for _ in range(-decpt):
                writer.write("0")
            writer.write(digits)
        elif decpt >= n:
            writer.write(digits)
            for _ in range(decpt - n):
                writer.write("0")
            writer.write(".0")
        else:
            writer.write(digits[byte=0:decpt], ".", digits[byte=decpt:n])
    else:
        writer.write(digits[byte=0:1])
        if n > 1:
            writer.write(".", digits[byte=1:n])
        var exp10 = decpt - 1
        writer.write("e-" if exp10 < 0 else "e+")
        var mag = -exp10 if exp10 < 0 else exp10
        if mag < 10:
            writer.write("0")
        writer.write(mag)


# ----------------------------------------------------------------------------
# Shortest round-trip decimal (Schubfach)
#
# Port of Raffaello Giulietti's Schubfach ("The Schubfach way to render
# doubles", 2020; OpenJDK's DoubleToDecimal since Java 19). Finds the
# shortest decimal in the rounding interval of a double, choosing the one
# closest to it (ties to even). Uses _SCHUBFACH_G, 126-bit approximations
# of 10^-k.
# ----------------------------------------------------------------------------

comptime _SF_Q_MIN = -1074  # exponent of the smallest subnormal
comptime _SF_C_MIN: UInt64 = 1 << 52  # smallest normal significand
comptime _SF_C_TINY: UInt64 = 3  # subnormals below this are special-cased
comptime _SF_K_MIN = -324  # smallest k in _SCHUBFACH_G
comptime _MASK63: UInt64 = (1 << 63) - 1


def _flog10pow2(e: Int) -> Int:
    """floor(e * log10(2))."""
    return (e * 661971961083) >> 41


def _flog10_three_quarters_pow2(e: Int) -> Int:
    """floor(log10(3/4 * 2^e))."""
    return (e * 661971961083 - 274743187321) >> 41


def _flog2pow10(e: Int) -> Int:
    """floor(e * log2(10))."""
    return (e * 913124641741) >> 38


def _rop(g1: UInt64, g0: UInt64, cp: UInt64) -> UInt64:
    """Round-to-odd of cp * g * 2^-127, where g = g1 * 2^63 + g0."""
    var x1 = UInt64((UInt128(g0) * UInt128(cp)) >> 64)
    var y = UInt128(g1) * UInt128(cp)
    var y0 = UInt64(y & 0xFFFFFFFFFFFFFFFF)
    var y1 = UInt64(y >> 64)
    var z = (y0 >> 1) + x1
    var vbp = y1 + (z >> 63)
    return vbp | (((z & _MASK63) + _MASK63) >> 63)


def _shortest_decimal(bits: UInt64) -> Tuple[UInt64, Int]:
    """(f, e) with f * 10^e the shortest decimal that rounds to the
    positive, finite, non-zero double with these bits (f may carry
    trailing zeros)."""
    var t = bits & (_SF_C_MIN - 1)
    var bq = Int(bits >> 52)
    if bq != 0:
        var mq = -_SF_Q_MIN + 1 - bq
        var c = _SF_C_MIN | t
        # Integers below 2^53 are their own shortest representation
        if mq > 0 and mq < 53:
            var f = c >> UInt64(mq)
            if (f << UInt64(mq)) == c:
                return (f, 0)
        return _schubfach(-mq, c, 0)
    if t < _SF_C_TINY:
        # The two smallest subnormals. Java renders them with two digits
        # (4.9e-324, 9.9e-324); the shortest, closest forms (as in CPython
        # repr) are single digits.
        return (UInt64(5), -324) if t == 1 else (UInt64(1), -323)
    return _schubfach(_SF_Q_MIN, t, 0)


def _schubfach(q: Int, c: UInt64, dk: Int) -> Tuple[UInt64, Int]:
    """Core of Schubfach for the value c * 2^q (figure 7 of the paper)."""
    var out = c & 1
    var cb = c << 2
    var cbr = cb + 2
    var cbl: UInt64
    var k: Int
    if c != _SF_C_MIN or q == _SF_Q_MIN:
        cbl = cb - 2  # regular spacing
        k = _flog10pow2(q)
    else:
        cbl = cb - 1  # irregular spacing (power of two)
        k = _flog10_three_quarters_pow2(q)
    var h = UInt64(q + _flog2pow10(-k) + 2)
    ref table = global_constant[_SCHUBFACH_G]()
    var index = 2 * (k - _SF_K_MIN)
    var g1 = table[index]
    var g0 = table[index + 1]
    var vb = _rop(g1, g0, cb << h)
    var vbl = _rop(g1, g0, cbl << h)
    var vbr = _rop(g1, g0, cbr << h)

    var s = vb >> 2
    # Try one digit fewer: s' = floor(s / 10). Java only does this for
    # s >= 100 (it always emits two digits); s in [10, 100) occurs only for
    # tiny subnormals, whose single-digit shortest form CPython prints.
    if s >= 10:
        var sp10 = 10 * (s // 10)
        var tp10 = sp10 + 10
        var upin = vbl + out <= sp10 << 2
        var wpin = (tp10 << 2) + out <= vbr
        if upin != wpin:
            return (sp10 if upin else tp10, k)
    var t = s + 1
    var uin = vbl + out <= s << 2
    var win = (t << 2) + out <= vbr
    if uin != win:
        return (s if uin else t, k + dk)
    # Both candidates round-trip: take the closer one (ties to even)
    var cmp = Int64(vb) - Int64((s + t) << 1)
    return (s if cmp < 0 or (cmp == 0 and (s & 1) == 0) else t, k + dk)


def _float_to_int(x: Float64) raises -> Int:
    """Truncate a Float64 to Int, raising if it is outside Int64 range."""
    if isnan(x) or x < _INT_MIN_F or x >= _INT_MAX_F:
        raise Error("number " + String(x) + " is out of Int range")
    return Int(x)


# ============================================================================
# JsonObject — Key/Value Storage
# ============================================================================


struct JsonObject(Copyable, Movable, Sized, Writable):
    """JSON object: keys in insertion order, with a hash index for large
    objects.

    Keys and values live in parallel lists. Small objects look keys up
    with a linear scan; once an object reaches _INDEX_THRESHOLD keys a
    key -> position Dict is built and maintained.
    """

    var _keys: List[String]
    var _values: List[JsonValue]
    # Built once the object reaches _INDEX_THRESHOLD keys; boxed so small
    # objects stay small.
    var _index: Optional[OwnedPointer[Dict[String, Int]]]

    def __init__(out self, capacity: Int = 0):
        self._keys = List[String](capacity=capacity)
        self._values = List[JsonValue](capacity=capacity)
        self._index = None

    def __init__(out self, *, copy: Self):
        self._keys = copy._keys.copy()
        self._values = copy._values.copy()
        if copy._index:
            self._index = OwnedPointer(copy._index.value()[].copy())
        else:
            self._index = None

    def __init__(out self, *, deinit move: Self):
        self._keys = move._keys^
        self._values = move._values^
        self._index = move._index^

    def _find(self, key: String) -> Int:
        """Return the position of key, or -1 if absent."""
        if self._index:
            var i = self._index.value()[].get(key)
            if i:
                return i.value()
            return -1
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return i
        return -1

    def set(mut self, key: String, var value: JsonValue):
        """Set a key-value pair. Overwrites in place if key exists."""
        var i = self._find(key)
        if i >= 0:
            self._values[i] = value^
            return
        self._keys.append(key)
        self._values.append(value^)
        var n = len(self._keys)
        if n == _INDEX_THRESHOLD:
            var index = Dict[String, Int]()
            for j in range(n):
                index[self._keys[j]] = j
            self._index = OwnedPointer(index^)
        elif n > _INDEX_THRESHOLD:
            self._index.value()[][key] = n - 1

    def get(self, key: String) raises -> JsonValue:
        """Get a deep copy of the value for key. Raises if not found."""
        var i = self._find(key)
        if i < 0:
            raise Error("JSON key not found: " + key)
        return self._values[i].copy()

    def has_key(self, key: String) -> Bool:
        """Check if key exists."""
        return self._find(key) >= 0

    def keys(self) -> List[String]:
        """Return a copy of the keys, in insertion order."""
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
        return String(self)


# ============================================================================
# JsonValue — Tagged Union
# ============================================================================


struct JsonValue(Boolable, Copyable, Movable, SizedRaising, Writable):
    """A JSON value: null, bool, number, string, array, or object.

    Arrays and objects are heap-allocated behind a pointer so the type
    can contain itself. Copies are deep.

    Numbers keep an exact Int when the source was an integer literal that
    fits in Int64 (see is_int()); otherwise they are Float64.
    """

    var kind: Int
    var _bool_val: Bool
    var _is_int: Bool
    # Number payload: an Int when _is_int, else the bits of a Float64
    # (one shared slot keeps JsonValue at 64 bytes).
    var _num: Int
    var _str_val: String
    var _arr_ptr: Optional[Pointer[List[JsonValue], MutUntrackedOrigin]]
    var _obj_ptr: Optional[Pointer[JsonObject, MutUntrackedOrigin]]

    def __init__(out self):
        """Create a null JsonValue."""
        self.kind = JSON_NULL
        self._bool_val = False
        self._is_int = False
        self._num = 0
        self._str_val = String("")
        self._arr_ptr = None
        self._obj_ptr = None

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self._bool_val = copy._bool_val
        self._is_int = copy._is_int
        self._num = copy._num
        self._str_val = copy._str_val
        # Deep copy heap-allocated data
        if copy._arr_ptr:
            var p = unsafe_alloc[List[JsonValue]](1)
            p.unsafe_write(copy=copy._arr_ptr.unsafe_value()[])
            self._arr_ptr = Optional(p)
        else:
            self._arr_ptr = None
        if copy._obj_ptr:
            var p = unsafe_alloc[JsonObject](1)
            p.unsafe_write(copy=copy._obj_ptr.unsafe_value()[])
            self._obj_ptr = Optional(p)
        else:
            self._obj_ptr = None

    def __init__(out self, *, deinit move: Self):
        self.kind = move.kind
        self._bool_val = move._bool_val
        self._is_int = move._is_int
        self._num = move._num
        self._str_val = move._str_val^
        self._arr_ptr = move._arr_ptr
        self._obj_ptr = move._obj_ptr

    def __deinit__(deinit self):
        if self._arr_ptr:
            self._arr_ptr.unsafe_value().unsafe_deinit_pointee()
            self._arr_ptr.unsafe_value().unsafe_free()
        if self._obj_ptr:
            self._obj_ptr.unsafe_value().unsafe_deinit_pointee()
            self._obj_ptr.unsafe_value().unsafe_free()

    def copy(self) -> Self:
        """Explicit deep copy."""
        return Self(copy=self)

    def _float(self) -> Float64:
        """Number payload as Float64 (only meaningful for numbers)."""
        if self._is_int:
            return Float64(self._num)
        return bitcast[DType.float64](Int64(self._num))

    # ------------------------------------------------------------------
    # Type checks
    # ------------------------------------------------------------------

    def is_null(self) -> Bool:
        return self.kind == JSON_NULL

    def is_bool(self) -> Bool:
        return self.kind == JSON_BOOL

    def is_number(self) -> Bool:
        return self.kind == JSON_NUMBER

    def is_int(self) -> Bool:
        """True if this is a number stored as an exact Int."""
        return self.kind == JSON_NUMBER and self._is_int

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
        return self._float()

    def as_int(self) raises -> Int:
        """Get number value as Int (floats are truncated).

        Raises if not a number or if the value is outside Int64 range.
        """
        if self.kind != JSON_NUMBER:
            raise Error("JsonValue is not a number")
        if self._is_int:
            return self._num
        return _float_to_int(self._float())

    def as_string(self) raises -> String:
        """Get string value. Raises if not a string."""
        if self.kind != JSON_STRING:
            raise Error("JsonValue is not a string")
        return self._str_val

    # ------------------------------------------------------------------
    # Internal lookup helpers
    # ------------------------------------------------------------------

    def _key_index(self, key: String) raises -> Int:
        """Position of key in this object. Raises if not an object or
        the key is missing."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            raise Error("object is null")
        var i = self._obj_ptr.unsafe_value()[]._find(key)
        if i < 0:
            raise Error("JSON key not found: " + key)
        return i

    def _check_index(self, index: Int) raises:
        """Raise unless this is an array and index is in bounds."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonValue is not an array")
        if not self._arr_ptr:
            raise Error("array is null")
        if index < 0 or index >= len(self._arr_ptr.unsafe_value()[]):
            raise Error("array index out of bounds: " + String(index))

    # ------------------------------------------------------------------
    # Array / object accessors (return deep copies)
    # ------------------------------------------------------------------

    def get(self, index: Int) raises -> JsonValue:
        """Get a deep copy of an array element. Raises if not an array
        or out of bounds."""
        self._check_index(index)
        return self._arr_ptr.unsafe_value()[][index].copy()

    def get(self, key: String) raises -> JsonValue:
        """Get a deep copy of an object value. Raises if not an object
        or the key is missing."""
        var i = self._key_index(key)
        return self._obj_ptr.unsafe_value()[]._values[i].copy()

    def __len__(self) raises -> Int:
        """Length of an array or object, or codepoint count of a string."""
        if self.kind == JSON_ARRAY:
            if not self._arr_ptr:
                return 0
            return len(self._arr_ptr.unsafe_value()[])
        elif self.kind == JSON_OBJECT:
            if not self._obj_ptr:
                return 0
            return len(self._obj_ptr.unsafe_value()[])
        elif self.kind == JSON_STRING:
            return len(self._str_val.codepoints())
        raise Error("JsonValue of kind " + String(self.kind) + " has no len()")

    def has_key(self, key: String) raises -> Bool:
        """Check if object has key. Raises if not an object."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            return False
        return self._obj_ptr.unsafe_value()[].has_key(key)

    def keys(self) raises -> List[String]:
        """Get object keys in insertion order. Raises if not an object."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonValue is not an object")
        if not self._obj_ptr:
            return List[String]()
        return self._obj_ptr.unsafe_value()[].keys()

    # ------------------------------------------------------------------
    # Leaf accessors — extract primitives without deep-copying the tree
    # ------------------------------------------------------------------

    def get_string(self, key: String) raises -> String:
        """Get string value by key without deep copy."""
        var i = self._key_index(key)
        var obj = self._obj_ptr.unsafe_value()
        if obj[]._values[i].kind != JSON_STRING:
            raise Error("value for '" + key + "' is not a string")
        return obj[]._values[i]._str_val

    def get_int(self, key: String) raises -> Int:
        """Get integer value by key without deep copy."""
        var i = self._key_index(key)
        var obj = self._obj_ptr.unsafe_value()
        if obj[]._values[i].kind != JSON_NUMBER:
            raise Error("value for '" + key + "' is not a number")
        return obj[]._values[i].as_int()

    def get_number(self, key: String) raises -> Float64:
        """Get number value by key without deep copy."""
        var i = self._key_index(key)
        var obj = self._obj_ptr.unsafe_value()
        if obj[]._values[i].kind != JSON_NUMBER:
            raise Error("value for '" + key + "' is not a number")
        return obj[]._values[i]._float()

    def get_bool(self, key: String) raises -> Bool:
        """Get boolean value by key without deep copy."""
        var i = self._key_index(key)
        var obj = self._obj_ptr.unsafe_value()
        if obj[]._values[i].kind != JSON_BOOL:
            raise Error("value for '" + key + "' is not a bool")
        return obj[]._values[i]._bool_val

    def get_string(self, index: Int) raises -> String:
        """Get string value by array index without deep copy."""
        self._check_index(index)
        var arr = self._arr_ptr.unsafe_value()
        if arr[][index].kind != JSON_STRING:
            raise Error("value at index " + String(index) + " is not a string")
        return arr[][index]._str_val

    def get_int(self, index: Int) raises -> Int:
        """Get integer value by array index without deep copy."""
        self._check_index(index)
        var arr = self._arr_ptr.unsafe_value()
        if arr[][index].kind != JSON_NUMBER:
            raise Error("value at index " + String(index) + " is not a number")
        return arr[][index].as_int()

    def get_number(self, index: Int) raises -> Float64:
        """Get number value by array index without deep copy."""
        self._check_index(index)
        var arr = self._arr_ptr.unsafe_value()
        if arr[][index].kind != JSON_NUMBER:
            raise Error("value at index " + String(index) + " is not a number")
        return arr[][index]._float()

    def get_bool(self, index: Int) raises -> Bool:
        """Get boolean value by array index without deep copy."""
        self._check_index(index)
        var arr = self._arr_ptr.unsafe_value()
        if arr[][index].kind != JSON_BOOL:
            raise Error("value at index " + String(index) + " is not a bool")
        return arr[][index]._bool_val

    def get_array_len(self, key: String) raises -> Int:
        """Get length of a nested array by key without copying it."""
        var i = self._key_index(key)
        var obj = self._obj_ptr.unsafe_value()
        if obj[]._values[i].kind != JSON_ARRAY:
            raise Error("value for '" + key + "' is not an array")
        if not obj[]._values[i]._arr_ptr:
            return 0
        return len(obj[]._values[i]._arr_ptr.unsafe_value()[])

    # ------------------------------------------------------------------
    # Mutation
    # ------------------------------------------------------------------

    def append(mut self, var value: JsonValue) raises:
        """Append to an array. Raises if not an array."""
        if self.kind != JSON_ARRAY or not self._arr_ptr:
            raise Error("append() requires an array")
        self._arr_ptr.unsafe_value()[].append(value^)

    def set(mut self, key: String, var value: JsonValue) raises:
        """Set an object key (overwrites in place). Raises if not an
        object."""
        if self.kind != JSON_OBJECT or not self._obj_ptr:
            raise Error("set() requires an object")
        self._obj_ptr.unsafe_value()[].set(key, value^)

    # ------------------------------------------------------------------
    # Pythonic API: subscript, contains, bool, print
    # ------------------------------------------------------------------

    def __getitem__(self, key: String) raises -> JsonValue:
        """Subscript access by string key: val["key"] (deep copy)."""
        return self.get(key)

    def __getitem__(self, index: Int) raises -> JsonValue:
        """Subscript access by integer index: val[0] (deep copy)."""
        return self.get(index)

    def __contains__(self, key: String) -> Bool:
        """Check if key exists in object: 'key' in val."""
        if self.kind != JSON_OBJECT:
            return False
        if not self._obj_ptr:
            return False
        return self._obj_ptr.unsafe_value()[].has_key(key)

    def __bool__(self) -> Bool:
        """Truthiness: null→False, bool→value, number→non-zero, string/array/object→non-empty.
        """
        if self.kind == JSON_NULL:
            return False
        elif self.kind == JSON_BOOL:
            return self._bool_val
        elif self.kind == JSON_NUMBER:
            return self._num != 0 if self._is_int else self._float() != 0.0
        elif self.kind == JSON_STRING:
            return self._str_val.byte_length() > 0
        elif self.kind == JSON_ARRAY:
            if self._arr_ptr:
                return len(self._arr_ptr.unsafe_value()[]) > 0
            return False
        elif self.kind == JSON_OBJECT:
            if self._obj_ptr:
                return len(self._obj_ptr.unsafe_value()[]) > 0
            return False
        return False

    def write_to[W: Writer](self, mut writer: W):
        """Serialize as a JSON string (used by print() and String())."""
        if self.kind == JSON_NULL:
            writer.write("null")
        elif self.kind == JSON_BOOL:
            if self._bool_val:
                writer.write("true")
            else:
                writer.write("false")
        elif self.kind == JSON_NUMBER:
            if self._is_int:
                writer.write(self._num)
            else:
                _write_float(self._float(), writer)
        elif self.kind == JSON_STRING:
            writer.write('"')
            _write_escaped_string[W](self._str_val, writer)
            writer.write('"')
        elif self.kind == JSON_ARRAY:
            writer.write("[")
            if self._arr_ptr:
                var arr = self._arr_ptr.unsafe_value()
                for i in range(len(arr[])):
                    if i > 0:
                        writer.write(", ")
                    arr[][i].write_to(writer)
            writer.write("]")
        elif self.kind == JSON_OBJECT:
            if self._obj_ptr:
                self._obj_ptr.unsafe_value()[].write_to(writer)
            else:
                writer.write("{}")

    def __str__(self) -> String:
        return String(self)


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
    """Create a floating-point number JsonValue."""
    var v = JsonValue()
    v.kind = JSON_NUMBER
    v._num = Int(bitcast[DType.int64](value))
    return v^


def json_int(value: Int) -> JsonValue:
    """Create an exact integer number JsonValue."""
    var v = JsonValue()
    v.kind = JSON_NUMBER
    v._is_int = True
    v._num = value
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
    var p = unsafe_alloc[List[JsonValue]](1)
    p.unsafe_write(List[JsonValue]())  # no allocation until first append
    v._arr_ptr = Optional(p)
    return v^


def json_object() -> JsonValue:
    """Create an empty object JsonValue."""
    var v = JsonValue()
    v.kind = JSON_OBJECT
    var p = unsafe_alloc[JsonObject](1)
    p.unsafe_write(JsonObject())  # no allocation until first set
    v._obj_ptr = Optional(p)
    return v^


# ============================================================================
# Recursive Descent Parser
# ============================================================================


def parse_json(
    s: String, max_depth: Int = DEFAULT_MAX_DEPTH
) raises -> JsonValue:
    """Parse a JSON document into a JsonValue tree (strict RFC 8259).

    Args:
        s: JSON text to parse.
        max_depth: Maximum nesting of arrays/objects. Deeper input raises
            instead of exhausting the stack.

    Returns:
        The parsed JsonValue.

    Raises:
        Error if the input is not valid JSON, nests deeper than max_depth,
        or contains a number that overflows Float64.
    """
    var data_len = s.byte_length()
    if data_len == 0:
        raise Error("empty JSON input")
    # Parse directly from the string's bytes — no input copy
    var data_ptr = s.unsafe_ptr()
    var pos: Int = 0
    var result = _parse_value(data_ptr, data_len, pos, 0, max_depth)
    _skip_whitespace(data_ptr, data_len, pos)
    if pos != data_len:
        raise Error("unexpected trailing content at position " + String(pos))
    return result^


def _is_digit(c: UInt8) -> Bool:
    return c >= _ZERO and c <= _NINE


def _skip_whitespace(data_ptr: Pointer[UInt8, _], data_len: Int, mut pos: Int):
    """Skip spaces, tabs, newlines, and carriage returns."""
    while pos < data_len:
        var c = data_ptr[unsafe_offset=pos]
        if c == _SPACE or c == _TAB or c == _LF or c == _CR:
            pos += 1
        else:
            return


def _parse_value(
    data_ptr: Pointer[UInt8, _],
    data_len: Int,
    mut pos: Int,
    depth: Int,
    max_depth: Int,
) raises -> JsonValue:
    """Parse any JSON value starting at pos."""
    _skip_whitespace(data_ptr, data_len, pos)
    if pos >= data_len:
        raise Error("unexpected end of JSON input")

    var c = data_ptr[unsafe_offset=pos]

    if c == _QUOTE:
        var s = _parse_string(data_ptr, data_len, pos)
        return json_string(s^)
    elif c == _LBRACE:
        return _parse_object(data_ptr, data_len, pos, depth + 1, max_depth)
    elif c == _LBRACKET:
        return _parse_array(data_ptr, data_len, pos, depth + 1, max_depth)
    elif c == _LOWER_T:
        _expect_literal["true"](data_ptr, data_len, pos)
        return json_bool(True)
    elif c == _LOWER_F:
        _expect_literal["false"](data_ptr, data_len, pos)
        return json_bool(False)
    elif c == _LOWER_N:
        _expect_literal["null"](data_ptr, data_len, pos)
        return json_null()
    elif c == _MINUS or _is_digit(c):
        return _parse_number(data_ptr, data_len, pos)
    else:
        raise Error(
            "unexpected " + _describe_byte(c) + " at position " + String(pos)
        )


def _describe_byte(c: UInt8) -> String:
    """Printable description of an input byte for error messages. Raw
    control or non-ASCII bytes are shown in hex so attacker-controlled
    input cannot inject terminal escape sequences into logs."""
    if c >= 0x20 and c < 0x7F:
        return "character '" + chr(Int(c)) + "'"
    return "byte 0x" + _hex_digit(Int(c) >> 4) + _hex_digit(Int(c) & 0x0F)


def _parse_hex4(
    data_ptr: Pointer[UInt8, _], data_len: Int, pos: Int
) raises -> Int:
    """Parse exactly 4 hex digits at pos into a UTF-16 code unit."""
    if pos + 4 > data_len:
        raise Error("truncated \\u escape at position " + String(pos))
    var value = 0
    for i in range(pos, pos + 4):
        var c = data_ptr[unsafe_offset=i]
        var d: Int
        if _is_digit(c):
            d = Int(c - _ZERO)
        elif c >= _LOWER_A and c <= _LOWER_F:
            d = Int(c - _LOWER_A) + 10
        elif c >= _UPPER_A and c <= _UPPER_F:
            d = Int(c - _UPPER_A) + 10
        else:
            raise Error(
                "invalid hex digit in \\u escape at position " + String(i)
            )
        value = value * 16 + d
    return value


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append the UTF-8 encoding of a Unicode scalar value."""
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _parse_string(
    data_ptr: Pointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> String:
    """Parse a JSON string (pos should be at the opening quote)."""
    var start = pos
    if data_ptr[unsafe_offset=pos] != _QUOTE:
        raise Error("expected '\"' at position " + String(pos))
    pos += 1  # skip opening quote

    var result = List[UInt8](capacity=64)
    while pos < data_len:
        var c = data_ptr[unsafe_offset=pos]
        if c == _QUOTE:
            pos += 1  # skip closing quote
            return String(unsafe_from_utf8=result^)
        elif c < 0x20:
            raise Error(
                "unescaped control character in string at position "
                + String(pos)
            )
        elif c != _BACKSLASH:
            result.append(c)
            pos += 1
            continue

        pos += 1  # skip backslash
        if pos >= data_len:
            break
        var esc = data_ptr[unsafe_offset=pos]
        if esc == _QUOTE or esc == _BACKSLASH or esc == _SLASH:
            result.append(esc)
        elif esc == _LOWER_N:
            result.append(_LF)
        elif esc == _LOWER_R:
            result.append(_CR)
        elif esc == _LOWER_T:
            result.append(_TAB)
        elif esc == _LOWER_B:
            result.append(_BACKSPACE)
        elif esc == _LOWER_F:
            result.append(_FORMFEED)
        elif esc == _LOWER_U:
            var cp = _parse_hex4(data_ptr, data_len, pos + 1)
            pos += 5  # past 'uXXXX'
            if cp >= 0xD800 and cp <= 0xDBFF:
                # High surrogate: must be followed by a \u low surrogate
                if (
                    pos + 1 >= data_len
                    or data_ptr[unsafe_offset=pos] != _BACKSLASH
                    or data_ptr[unsafe_offset=pos + 1] != _LOWER_U
                ):
                    raise Error("unpaired surrogate at position " + String(pos))
                var lo = _parse_hex4(data_ptr, data_len, pos + 2)
                if lo < 0xDC00 or lo > 0xDFFF:
                    raise Error("unpaired surrogate at position " + String(pos))
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                pos += 6
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                raise Error("unpaired surrogate at position " + String(pos))
            _append_utf8(result, cp)
            continue  # pos already past the escape
        else:
            raise Error(
                "invalid escape \\ followed by "
                + _describe_byte(esc)
                + " at position "
                + String(pos)
            )
        pos += 1

    raise Error("unterminated string starting at position " + String(start))


def _parse_number(
    data_ptr: Pointer[UInt8, _], data_len: Int, mut pos: Int
) raises -> JsonValue:
    """Parse a JSON number per the RFC 8259 grammar:
    -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?

    A single pass validates the token and accumulates the first 19
    significant digits into m, so that value ~= m * 10^(dp - nd).
    Integers that fit in Int64 are stored exactly (returned as soon as
    the integer part ends); everything else, including integers too large
    for Int64, is converted to the nearest Float64 by _digits_to_float.
    """
    var start = pos
    var is_negative = False
    if data_ptr[unsafe_offset=pos] == _MINUS:
        is_negative = True
        pos += 1
    var digits_start = pos
    var m: UInt64 = 0
    var nd = 0  # significant digits held in m (at most 19)
    var dropped = False  # non-zero significant digits beyond the 19th
    var dp = 0  # decimal point position relative to the first significant digit

    # Integer part: a single 0, or a non-zero digit followed by digits
    if pos >= data_len or not _is_digit(data_ptr[unsafe_offset=pos]):
        raise Error("invalid number at position " + String(start))
    if data_ptr[unsafe_offset=pos] == _ZERO:
        pos += 1
    else:
        # Tight loop: accumulate unconditionally (UInt64 wraps past 19
        # digits, fixed up below; integers that long are rare).
        while pos < data_len:
            var d = data_ptr[unsafe_offset=pos] - _ZERO
            if d > 9:
                break
            m = m * 10 + UInt64(d)
            pos += 1
        dp = pos - digits_start
        nd = dp
        if nd > 19:
            m = 0
            for i in range(digits_start, digits_start + 19):
                m = m * 10 + UInt64(data_ptr[unsafe_offset=i] - _ZERO)
            for i in range(digits_start + 19, pos):
                if data_ptr[unsafe_offset=i] != _ZERO:
                    dropped = True
            nd = 19
    var int_digits = dp

    # Integer fast path: no fraction or exponent follows
    if pos >= data_len or (
        data_ptr[unsafe_offset=pos] != _DOT
        and data_ptr[unsafe_offset=pos] | 0x20 != _LOWER_E
    ):
        if int_digits <= 19 and m <= UInt64(Int.MAX):
            if is_negative and m == 0:
                return json_number(-0.0)
            var n = Int(m)
            return json_int(-n if is_negative else n)

    # Fraction: '.' followed by at least one digit
    if pos < data_len and data_ptr[unsafe_offset=pos] == _DOT:
        pos += 1
        if pos >= data_len or not _is_digit(data_ptr[unsafe_offset=pos]):
            raise Error("expected digit after '.' at position " + String(pos))
        while pos < data_len:
            var d = data_ptr[unsafe_offset=pos] - _ZERO
            if d > 9:
                break
            if nd == 0 and d == 0:
                dp -= 1  # 0.00x: leading zeros only move the decimal point
            elif nd < 19:
                m = m * 10 + UInt64(d)
                nd += 1
            elif d != 0:
                dropped = True
            pos += 1

    # Exponent: 'e'/'E', optional sign, at least one digit
    if pos < data_len and (
        data_ptr[unsafe_offset=pos] == _LOWER_E
        or data_ptr[unsafe_offset=pos] == _UPPER_E
    ):
        pos += 1
        var exp_negative = False
        if pos < data_len and data_ptr[unsafe_offset=pos] == _MINUS:
            exp_negative = True
            pos += 1
        elif pos < data_len and data_ptr[unsafe_offset=pos] == _PLUS:
            pos += 1
        if pos >= data_len or not _is_digit(data_ptr[unsafe_offset=pos]):
            raise Error("expected digit in exponent at position " + String(pos))
        var exp_value = 0
        while pos < data_len and _is_digit(data_ptr[unsafe_offset=pos]):
            # Clamp: anything this large already over/underflows
            if exp_value < 100_000_000:
                exp_value = exp_value * 10 + Int(
                    data_ptr[unsafe_offset=pos] - _ZERO
                )
            pos += 1
        dp += -exp_value if exp_negative else exp_value

    var result = _digits_to_float(
        m, nd, dp - nd, dropped, data_ptr, digits_start, pos
    )
    if isinf(result):
        raise Error("number out of range at position " + String(start))
    return json_number(-result if is_negative else result)


# BEGIN GENERATED FLOAT TABLES (tools/gen_float_tables.py; do not edit)
# fmt: off
comptime _POW5_128: InlineArray[UInt64, 1302] = [
    0xEEF453D6923BD65A, 0x113FAA2906A13B3F,  # 5^-342
    0x9558B4661B6565F8, 0x4AC7CA59A424C507,  # 5^-341
    0xBAAEE17FA23EBF76, 0x5D79BCF00D2DF649,  # 5^-340
    0xE95A99DF8ACE6F53, 0xF4D82C2C107973DC,  # 5^-339
    0x91D8A02BB6C10594, 0x79071B9B8A4BE869,  # 5^-338
    0xB64EC836A47146F9, 0x9748E2826CDEE284,  # 5^-337
    0xE3E27A444D8D98B7, 0xFD1B1B2308169B25,  # 5^-336
    0x8E6D8C6AB0787F72, 0xFE30F0F5E50E20F7,  # 5^-335
    0xB208EF855C969F4F, 0xBDBD2D335E51A935,  # 5^-334
    0xDE8B2B66B3BC4723, 0xAD2C788035E61382,  # 5^-333
    0x8B16FB203055AC76, 0x4C3BCB5021AFCC31,  # 5^-332
    0xADDCB9E83C6B1793, 0xDF4ABE242A1BBF3D,  # 5^-331
    0xD953E8624B85DD78, 0xD71D6DAD34A2AF0D,  # 5^-330
    0x87D4713D6F33AA6B, 0x8672648C40E5AD68,  # 5^-329
    0xA9C98D8CCB009506, 0x680EFDAF511F18C2,  # 5^-328
    0xD43BF0EFFDC0BA48, 0x0212BD1B2566DEF2,  # 5^-327
    0x84A57695FE98746D, 0x014BB630F7604B57,  # 5^-326
    0xA5CED43B7E3E9188, 0x419EA3BD35385E2D,  # 5^-325
    0xCF42894A5DCE35EA, 0x52064CAC828675B9,  # 5^-324
    0x818995CE7AA0E1B2, 0x7343EFEBD1940993,  # 5^-323
    0xA1EBFB4219491A1F, 0x1014EBE6C5F90BF8,  # 5^-322
    0xCA66FA129F9B60A6, 0xD41A26E077774EF6,  # 5^-321
    0xFD00B897478238D0, 0x8920B098955522B4,  # 5^-320
    0x9E20735E8CB16382, 0x55B46E5F5D5535B0,  # 5^-319
    0xC5A890362FDDBC62, 0xEB2189F734AA831D,  # 5^-318
    0xF712B443BBD52B7B, 0xA5E9EC7501D523E4,  # 5^-317
    0x9A6BB0AA55653B2D, 0x47B233C92125366E,  # 5^-316
    0xC1069CD4EABE89F8, 0x999EC0BB696E840A,  # 5^-315
    0xF148440A256E2C76, 0xC00670EA43CA250D,  # 5^-314
    0x96CD2A865764DBCA, 0x380406926A5E5728,  # 5^-313
    0xBC807527ED3E12BC, 0xC605083704F5ECF2,  # 5^-312
    0xEBA09271E88D976B, 0xF7864A44C633682E,  # 5^-311
    0x93445B8731587EA3, 0x7AB3EE6AFBE0211D,  # 5^-310
    0xB8157268FDAE9E4C, 0x5960EA05BAD82964,  # 5^-309
    0xE61ACF033D1A45DF, 0x6FB92487298E33BD,  # 5^-308
    0x8FD0C16206306BAB, 0xA5D3B6D479F8E056,  # 5^-307
    0xB3C4F1BA87BC8696, 0x8F48A4899877186C,  # 5^-306
    0xE0B62E2929ABA83C, 0x331ACDABFE94DE87,  # 5^-305
    0x8C71DCD9BA0B4925, 0x9FF0C08B7F1D0B14,  # 5^-304
    0xAF8E5410288E1B6F, 0x07ECF0AE5EE44DD9,  # 5^-303
    0xDB71E91432B1A24A, 0xC9E82CD9F69D6150,  # 5^-302
    0x892731AC9FAF056E, 0xBE311C083A225CD2,  # 5^-301
    0xAB70FE17C79AC6CA, 0x6DBD630A48AAF406,  # 5^-300
    0xD64D3D9DB981787D, 0x092CBBCCDAD5B108,  # 5^-299
    0x85F0468293F0EB4E, 0x25BBF56008C58EA5,  # 5^-298
    0xA76C582338ED2621, 0xAF2AF2B80AF6F24E,  # 5^-297
    0xD1476E2C07286FAA, 0x1AF5AF660DB4AEE1,  # 5^-296
    0x82CCA4DB847945CA, 0x50D98D9FC890ED4D,  # 5^-295
    0xA37FCE126597973C, 0xE50FF107BAB528A0,  # 5^-294
    0xCC5FC196FEFD7D0C, 0x1E53ED49A96272C8,  # 5^-293
    0xFF77B1FCBEBCDC4F, 0x25E8E89C13BB0F7A,  # 5^-292
    0x9FAACF3DF73609B1, 0x77B191618C54E9AC,  # 5^-291
    0xC795830D75038C1D, 0xD59DF5B9EF6A2417,  # 5^-290
    0xF97AE3D0D2446F25, 0x4B0573286B44AD1D,  # 5^-289
    0x9BECCE62836AC577, 0x4EE367F9430AEC32,  # 5^-288
    0xC2E801FB244576D5, 0x229C41F793CDA73F,  # 5^-287
    0xF3A20279ED56D48A, 0x6B43527578C1110F,  # 5^-286
    0x9845418C345644D6, 0x830A13896B78AAA9,  # 5^-285
    0xBE5691EF416BD60C, 0x23CC986BC656D553,  # 5^-284
    0xEDEC366B11C6CB8F, 0x2CBFBE86B7EC8AA8,  # 5^-283
    0x94B3A202EB1C3F39, 0x7BF7D71432F3D6A9,  # 5^-282
    0xB9E08A83A5E34F07, 0xDAF5CCD93FB0CC53,  # 5^-281
    0xE858AD248F5C22C9, 0xD1B3400F8F9CFF68,  # 5^-280
    0x91376C36D99995BE, 0x23100809B9C21FA1,  # 5^-279
    0xB58547448FFFFB2D, 0xABD40A0C2832A78A,  # 5^-278
    0xE2E69915B3FFF9F9, 0x16C90C8F323F516C,  # 5^-277
    0x8DD01FAD907FFC3B, 0xAE3DA7D97F6792E3,  # 5^-276
    0xB1442798F49FFB4A, 0x99CD11CFDF41779C,  # 5^-275
    0xDD95317F31C7FA1D, 0x40405643D711D583,  # 5^-274
    0x8A7D3EEF7F1CFC52, 0x482835EA666B2572,  # 5^-273
    0xAD1C8EAB5EE43B66, 0xDA3243650005EECF,  # 5^-272
    0xD863B256369D4A40, 0x90BED43E40076A82,  # 5^-271
    0x873E4F75E2224E68, 0x5A7744A6E804A291,  # 5^-270
    0xA90DE3535AAAE202, 0x711515D0A205CB36,  # 5^-269
    0xD3515C2831559A83, 0x0D5A5B44CA873E03,  # 5^-268
    0x8412D9991ED58091, 0xE858790AFE9486C2,  # 5^-267
    0xA5178FFF668AE0B6, 0x626E974DBE39A872,  # 5^-266
    0xCE5D73FF402D98E3, 0xFB0A3D212DC8128F,  # 5^-265
    0x80FA687F881C7F8E, 0x7CE66634BC9D0B99,  # 5^-264
    0xA139029F6A239F72, 0x1C1FFFC1EBC44E80,  # 5^-263
    0xC987434744AC874E, 0xA327FFB266B56220,  # 5^-262
    0xFBE9141915D7A922, 0x4BF1FF9F0062BAA8,  # 5^-261
    0x9D71AC8FADA6C9B5, 0x6F773FC3603DB4A9,  # 5^-260
    0xC4CE17B399107C22, 0xCB550FB4384D21D3,  # 5^-259
    0xF6019DA07F549B2B, 0x7E2A53A146606A48,  # 5^-258
    0x99C102844F94E0FB, 0x2EDA7444CBFC426D,  # 5^-257
    0xC0314325637A1939, 0xFA911155FEFB5308,  # 5^-256
    0xF03D93EEBC589F88, 0x793555AB7EBA27CA,  # 5^-255
    0x96267C7535B763B5, 0x4BC1558B2F3458DE,  # 5^-254
    0xBBB01B9283253CA2, 0x9EB1AAEDFB016F16,  # 5^-253
    0xEA9C227723EE8BCB, 0x465E15A979C1CADC,  # 5^-252
    0x92A1958A7675175F, 0x0BFACD89EC191EC9,  # 5^-251
    0xB749FAED14125D36, 0xCEF980EC671F667B,  # 5^-250
    0xE51C79A85916F484, 0x82B7E12780E7401A,  # 5^-249
    0x8F31CC0937AE58D2, 0xD1B2ECB8B0908810,  # 5^-248
    0xB2FE3F0B8599EF07, 0x861FA7E6DCB4AA15,  # 5^-247
    0xDFBDCECE67006AC9, 0x67A791E093E1D49A,  # 5^-246
    0x8BD6A141006042BD, 0xE0C8BB2C5C6D24E0,  # 5^-245
    0xAECC49914078536D, 0x58FAE9F773886E18,  # 5^-244
    0xDA7F5BF590966848, 0xAF39A475506A899E,  # 5^-243
    0x888F99797A5E012D, 0x6D8406C952429603,  # 5^-242
    0xAAB37FD7D8F58178, 0xC8E5087BA6D33B83,  # 5^-241
    0xD5605FCDCF32E1D6, 0xFB1E4A9A90880A64,  # 5^-240
    0x855C3BE0A17FCD26, 0x5CF2EEA09A55067F,  # 5^-239
    0xA6B34AD8C9DFC06F, 0xF42FAA48C0EA481E,  # 5^-238
    0xD0601D8EFC57B08B, 0xF13B94DAF124DA26,  # 5^-237
    0x823C12795DB6CE57, 0x76C53D08D6B70858,  # 5^-236
    0xA2CB1717B52481ED, 0x54768C4B0C64CA6E,  # 5^-235
    0xCB7DDCDDA26DA268, 0xA9942F5DCF7DFD09,  # 5^-234
    0xFE5D54150B090B02, 0xD3F93B35435D7C4C,  # 5^-233
    0x9EFA548D26E5A6E1, 0xC47BC5014A1A6DAF,  # 5^-232
    0xC6B8E9B0709F109A, 0x359AB6419CA1091B,  # 5^-231
    0xF867241C8CC6D4C0, 0xC30163D203C94B62,  # 5^-230
    0x9B407691D7FC44F8, 0x79E0DE63425DCF1D,  # 5^-229
    0xC21094364DFB5636, 0x985915FC12F542E4,  # 5^-228
    0xF294B943E17A2BC4, 0x3E6F5B7B17B2939D,  # 5^-227
    0x979CF3CA6CEC5B5A, 0xA705992CEECF9C42,  # 5^-226
    0xBD8430BD08277231, 0x50C6FF782A838353,  # 5^-225
    0xECE53CEC4A314EBD, 0xA4F8BF5635246428,  # 5^-224
    0x940F4613AE5ED136, 0x871B7795E136BE99,  # 5^-223
    0xB913179899F68584, 0x28E2557B59846E3F,  # 5^-222
    0xE757DD7EC07426E5, 0x331AEADA2FE589CF,  # 5^-221
    0x9096EA6F3848984F, 0x3FF0D2C85DEF7621,  # 5^-220
    0xB4BCA50B065ABE63, 0x0FED077A756B53A9,  # 5^-219
    0xE1EBCE4DC7F16DFB, 0xD3E8495912C62894,  # 5^-218
    0x8D3360F09CF6E4BD, 0x64712DD7ABBBD95C,  # 5^-217
    0xB080392CC4349DEC, 0xBD8D794D96AACFB3,  # 5^-216
    0xDCA04777F541C567, 0xECF0D7A0FC5583A0,  # 5^-215
    0x89E42CAAF9491B60, 0xF41686C49DB57244,  # 5^-214
    0xAC5D37D5B79B6239, 0x311C2875C522CED5,  # 5^-213
    0xD77485CB25823AC7, 0x7D633293366B828B,  # 5^-212
    0x86A8D39EF77164BC, 0xAE5DFF9C02033197,  # 5^-211
    0xA8530886B54DBDEB, 0xD9F57F830283FDFC,  # 5^-210
    0xD267CAA862A12D66, 0xD072DF63C324FD7B,  # 5^-209
    0x8380DEA93DA4BC60, 0x4247CB9E59F71E6D,  # 5^-208
    0xA46116538D0DEB78, 0x52D9BE85F074E608,  # 5^-207
    0xCD795BE870516656, 0x67902E276C921F8B,  # 5^-206
    0x806BD9714632DFF6, 0x00BA1CD8A3DB53B6,  # 5^-205
    0xA086CFCD97BF97F3, 0x80E8A40ECCD228A4,  # 5^-204
    0xC8A883C0FDAF7DF0, 0x6122CD128006B2CD,  # 5^-203
    0xFAD2A4B13D1B5D6C, 0x796B805720085F81,  # 5^-202
    0x9CC3A6EEC6311A63, 0xCBE3303674053BB0,  # 5^-201
    0xC3F490AA77BD60FC, 0xBEDBFC4411068A9C,  # 5^-200
    0xF4F1B4D515ACB93B, 0xEE92FB5515482D44,  # 5^-199
    0x991711052D8BF3C5, 0x751BDD152D4D1C4A,  # 5^-198
    0xBF5CD54678EEF0B6, 0xD262D45A78A0635D,  # 5^-197
    0xEF340A98172AACE4, 0x86FB897116C87C34,  # 5^-196
    0x9580869F0E7AAC0E, 0xD45D35E6AE3D4DA0,  # 5^-195
    0xBAE0A846D2195712, 0x8974836059CCA109,  # 5^-194
    0xE998D258869FACD7, 0x2BD1A438703FC94B,  # 5^-193
    0x91FF83775423CC06, 0x7B6306A34627DDCF,  # 5^-192
    0xB67F6455292CBF08, 0x1A3BC84C17B1D542,  # 5^-191
    0xE41F3D6A7377EECA, 0x20CABA5F1D9E4A93,  # 5^-190
    0x8E938662882AF53E, 0x547EB47B7282EE9C,  # 5^-189
    0xB23867FB2A35B28D, 0xE99E619A4F23AA43,  # 5^-188
    0xDEC681F9F4C31F31, 0x6405FA00E2EC94D4,  # 5^-187
    0x8B3C113C38F9F37E, 0xDE83BC408DD3DD04,  # 5^-186
    0xAE0B158B4738705E, 0x9624AB50B148D445,  # 5^-185
    0xD98DDAEE19068C76, 0x3BADD624DD9B0957,  # 5^-184
    0x87F8A8D4CFA417C9, 0xE54CA5D70A80E5D6,  # 5^-183
    0xA9F6D30A038D1DBC, 0x5E9FCF4CCD211F4C,  # 5^-182
    0xD47487CC8470652B, 0x7647C3200069671F,  # 5^-181
    0x84C8D4DFD2C63F3B, 0x29ECD9F40041E073,  # 5^-180
    0xA5FB0A17C777CF09, 0xF468107100525890,  # 5^-179
    0xCF79CC9DB955C2CC, 0x7182148D4066EEB4,  # 5^-178
    0x81AC1FE293D599BF, 0xC6F14CD848405530,  # 5^-177
    0xA21727DB38CB002F, 0xB8ADA00E5A506A7C,  # 5^-176
    0xCA9CF1D206FDC03B, 0xA6D90811F0E4851C,  # 5^-175
    0xFD442E4688BD304A, 0x908F4A166D1DA663,  # 5^-174
    0x9E4A9CEC15763E2E, 0x9A598E4E043287FE,  # 5^-173
    0xC5DD44271AD3CDBA, 0x40EFF1E1853F29FD,  # 5^-172
    0xF7549530E188C128, 0xD12BEE59E68EF47C,  # 5^-171
    0x9A94DD3E8CF578B9, 0x82BB74F8301958CE,  # 5^-170
    0xC13A148E3032D6E7, 0xE36A52363C1FAF01,  # 5^-169
    0xF18899B1BC3F8CA1, 0xDC44E6C3CB279AC1,  # 5^-168
    0x96F5600F15A7B7E5, 0x29AB103A5EF8C0B9,  # 5^-167
    0xBCB2B812DB11A5DE, 0x7415D448F6B6F0E7,  # 5^-166
    0xEBDF661791D60F56, 0x111B495B3464AD21,  # 5^-165
    0x936B9FCEBB25C995, 0xCAB10DD900BEEC34,  # 5^-164
    0xB84687C269EF3BFB, 0x3D5D514F40EEA742,  # 5^-163
    0xE65829B3046B0AFA, 0x0CB4A5A3112A5112,  # 5^-162
    0x8FF71A0FE2C2E6DC, 0x47F0E785EABA72AB,  # 5^-161
    0xB3F4E093DB73A093, 0x59ED216765690F56,  # 5^-160
    0xE0F218B8D25088B8, 0x306869C13EC3532C,  # 5^-159
    0x8C974F7383725573, 0x1E414218C73A13FB,  # 5^-158
    0xAFBD2350644EEACF, 0xE5D1929EF90898FA,  # 5^-157
    0xDBAC6C247D62A583, 0xDF45F746B74ABF39,  # 5^-156
    0x894BC396CE5DA772, 0x6B8BBA8C328EB783,  # 5^-155
    0xAB9EB47C81F5114F, 0x066EA92F3F326564,  # 5^-154
    0xD686619BA27255A2, 0xC80A537B0EFEFEBD,  # 5^-153
    0x8613FD0145877585, 0xBD06742CE95F5F36,  # 5^-152
    0xA798FC4196E952E7, 0x2C48113823B73704,  # 5^-151
    0xD17F3B51FCA3A7A0, 0xF75A15862CA504C5,  # 5^-150
    0x82EF85133DE648C4, 0x9A984D73DBE722FB,  # 5^-149
    0xA3AB66580D5FDAF5, 0xC13E60D0D2E0EBBA,  # 5^-148
    0xCC963FEE10B7D1B3, 0x318DF905079926A8,  # 5^-147
    0xFFBBCFE994E5C61F, 0xFDF17746497F7052,  # 5^-146
    0x9FD561F1FD0F9BD3, 0xFEB6EA8BEDEFA633,  # 5^-145
    0xC7CABA6E7C5382C8, 0xFE64A52EE96B8FC0,  # 5^-144
    0xF9BD690A1B68637B, 0x3DFDCE7AA3C673B0,  # 5^-143
    0x9C1661A651213E2D, 0x06BEA10CA65C084E,  # 5^-142
    0xC31BFA0FE5698DB8, 0x486E494FCFF30A62,  # 5^-141
    0xF3E2F893DEC3F126, 0x5A89DBA3C3EFCCFA,  # 5^-140
    0x986DDB5C6B3A76B7, 0xF89629465A75E01C,  # 5^-139
    0xBE89523386091465, 0xF6BBB397F1135823,  # 5^-138
    0xEE2BA6C0678B597F, 0x746AA07DED582E2C,  # 5^-137
    0x94DB483840B717EF, 0xA8C2A44EB4571CDC,  # 5^-136
    0xBA121A4650E4DDEB, 0x92F34D62616CE413,  # 5^-135
    0xE896A0D7E51E1566, 0x77B020BAF9C81D17,  # 5^-134
    0x915E2486EF32CD60, 0x0ACE1474DC1D122E,  # 5^-133
    0xB5B5ADA8AAFF80B8, 0x0D819992132456BA,  # 5^-132
    0xE3231912D5BF60E6, 0x10E1FFF697ED6C69,  # 5^-131
    0x8DF5EFABC5979C8F, 0xCA8D3FFA1EF463C1,  # 5^-130
    0xB1736B96B6FD83B3, 0xBD308FF8A6B17CB2,  # 5^-129
    0xDDD0467C64BCE4A0, 0xAC7CB3F6D05DDBDE,  # 5^-128
    0x8AA22C0DBEF60EE4, 0x6BCDF07A423AA96B,  # 5^-127
    0xAD4AB7112EB3929D, 0x86C16C98D2C953C6,  # 5^-126
    0xD89D64D57A607744, 0xE871C7BF077BA8B7,  # 5^-125
    0x87625F056C7C4A8B, 0x11471CD764AD4972,  # 5^-124
    0xA93AF6C6C79B5D2D, 0xD598E40D3DD89BCF,  # 5^-123
    0xD389B47879823479, 0x4AFF1D108D4EC2C3,  # 5^-122
    0x843610CB4BF160CB, 0xCEDF722A585139BA,  # 5^-121
    0xA54394FE1EEDB8FE, 0xC2974EB4EE658828,  # 5^-120
    0xCE947A3DA6A9273E, 0x733D226229FEEA32,  # 5^-119
    0x811CCC668829B887, 0x0806357D5A3F525F,  # 5^-118
    0xA163FF802A3426A8, 0xCA07C2DCB0CF26F7,  # 5^-117
    0xC9BCFF6034C13052, 0xFC89B393DD02F0B5,  # 5^-116
    0xFC2C3F3841F17C67, 0xBBAC2078D443ACE2,  # 5^-115
    0x9D9BA7832936EDC0, 0xD54B944B84AA4C0D,  # 5^-114
    0xC5029163F384A931, 0x0A9E795E65D4DF11,  # 5^-113
    0xF64335BCF065D37D, 0x4D4617B5FF4A16D5,  # 5^-112
    0x99EA0196163FA42E, 0x504BCED1BF8E4E45,  # 5^-111
    0xC06481FB9BCF8D39, 0xE45EC2862F71E1D6,  # 5^-110
    0xF07DA27A82C37088, 0x5D767327BB4E5A4C,  # 5^-109
    0x964E858C91BA2655, 0x3A6A07F8D510F86F,  # 5^-108
    0xBBE226EFB628AFEA, 0x890489F70A55368B,  # 5^-107
    0xEADAB0ABA3B2DBE5, 0x2B45AC74CCEA842E,  # 5^-106
    0x92C8AE6B464FC96F, 0x3B0B8BC90012929D,  # 5^-105
    0xB77ADA0617E3BBCB, 0x09CE6EBB40173744,  # 5^-104
    0xE55990879DDCAABD, 0xCC420A6A101D0515,  # 5^-103
    0x8F57FA54C2A9EAB6, 0x9FA946824A12232D,  # 5^-102
    0xB32DF8E9F3546564, 0x47939822DC96ABF9,  # 5^-101
    0xDFF9772470297EBD, 0x59787E2B93BC56F7,  # 5^-100
    0x8BFBEA76C619EF36, 0x57EB4EDB3C55B65A,  # 5^-99
    0xAEFAE51477A06B03, 0xEDE622920B6B23F1,  # 5^-98
    0xDAB99E59958885C4, 0xE95FAB368E45ECED,  # 5^-97
    0x88B402F7FD75539B, 0x11DBCB0218EBB414,  # 5^-96
    0xAAE103B5FCD2A881, 0xD652BDC29F26A119,  # 5^-95
    0xD59944A37C0752A2, 0x4BE76D3346F0495F,  # 5^-94
    0x857FCAE62D8493A5, 0x6F70A4400C562DDB,  # 5^-93
    0xA6DFBD9FB8E5B88E, 0xCB4CCD500F6BB952,  # 5^-92
    0xD097AD07A71F26B2, 0x7E2000A41346A7A7,  # 5^-91
    0x825ECC24C873782F, 0x8ED400668C0C28C8,  # 5^-90
    0xA2F67F2DFA90563B, 0x728900802F0F32FA,  # 5^-89
    0xCBB41EF979346BCA, 0x4F2B40A03AD2FFB9,  # 5^-88
    0xFEA126B7D78186BC, 0xE2F610C84987BFA8,  # 5^-87
    0x9F24B832E6B0F436, 0x0DD9CA7D2DF4D7C9,  # 5^-86
    0xC6EDE63FA05D3143, 0x91503D1C79720DBB,  # 5^-85
    0xF8A95FCF88747D94, 0x75A44C6397CE912A,  # 5^-84
    0x9B69DBE1B548CE7C, 0xC986AFBE3EE11ABA,  # 5^-83
    0xC24452DA229B021B, 0xFBE85BADCE996168,  # 5^-82
    0xF2D56790AB41C2A2, 0xFAE27299423FB9C3,  # 5^-81
    0x97C560BA6B0919A5, 0xDCCD879FC967D41A,  # 5^-80
    0xBDB6B8E905CB600F, 0x5400E987BBC1C920,  # 5^-79
    0xED246723473E3813, 0x290123E9AAB23B68,  # 5^-78
    0x9436C0760C86E30B, 0xF9A0B6720AAF6521,  # 5^-77
    0xB94470938FA89BCE, 0xF808E40E8D5B3E69,  # 5^-76
    0xE7958CB87392C2C2, 0xB60B1D1230B20E04,  # 5^-75
    0x90BD77F3483BB9B9, 0xB1C6F22B5E6F48C2,  # 5^-74
    0xB4ECD5F01A4AA828, 0x1E38AEB6360B1AF3,  # 5^-73
    0xE2280B6C20DD5232, 0x25C6DA63C38DE1B0,  # 5^-72
    0x8D590723948A535F, 0x579C487E5A38AD0E,  # 5^-71
    0xB0AF48EC79ACE837, 0x2D835A9DF0C6D851,  # 5^-70
    0xDCDB1B2798182244, 0xF8E431456CF88E65,  # 5^-69
    0x8A08F0F8BF0F156B, 0x1B8E9ECB641B58FF,  # 5^-68
    0xAC8B2D36EED2DAC5, 0xE272467E3D222F3F,  # 5^-67
    0xD7ADF884AA879177, 0x5B0ED81DCC6ABB0F,  # 5^-66
    0x86CCBB52EA94BAEA, 0x98E947129FC2B4E9,  # 5^-65
    0xA87FEA27A539E9A5, 0x3F2398D747B36224,  # 5^-64
    0xD29FE4B18E88640E, 0x8EEC7F0D19A03AAD,  # 5^-63
    0x83A3EEEEF9153E89, 0x1953CF68300424AC,  # 5^-62
    0xA48CEAAAB75A8E2B, 0x5FA8C3423C052DD7,  # 5^-61
    0xCDB02555653131B6, 0x3792F412CB06794D,  # 5^-60
    0x808E17555F3EBF11, 0xE2BBD88BBEE40BD0,  # 5^-59
    0xA0B19D2AB70E6ED6, 0x5B6ACEAEAE9D0EC4,  # 5^-58
    0xC8DE047564D20A8B, 0xF245825A5A445275,  # 5^-57
    0xFB158592BE068D2E, 0xEED6E2F0F0D56712,  # 5^-56
    0x9CED737BB6C4183D, 0x55464DD69685606B,  # 5^-55
    0xC428D05AA4751E4C, 0xAA97E14C3C26B886,  # 5^-54
    0xF53304714D9265DF, 0xD53DD99F4B3066A8,  # 5^-53
    0x993FE2C6D07B7FAB, 0xE546A8038EFE4029,  # 5^-52
    0xBF8FDB78849A5F96, 0xDE98520472BDD033,  # 5^-51
    0xEF73D256A5C0F77C, 0x963E66858F6D4440,  # 5^-50
    0x95A8637627989AAD, 0xDDE7001379A44AA8,  # 5^-49
    0xBB127C53B17EC159, 0x5560C018580D5D52,  # 5^-48
    0xE9D71B689DDE71AF, 0xAAB8F01E6E10B4A6,  # 5^-47
    0x9226712162AB070D, 0xCAB3961304CA70E8,  # 5^-46
    0xB6B00D69BB55C8D1, 0x3D607B97C5FD0D22,  # 5^-45
    0xE45C10C42A2B3B05, 0x8CB89A7DB77C506A,  # 5^-44
    0x8EB98A7A9A5B04E3, 0x77F3608E92ADB242,  # 5^-43
    0xB267ED1940F1C61C, 0x55F038B237591ED3,  # 5^-42
    0xDF01E85F912E37A3, 0x6B6C46DEC52F6688,  # 5^-41
    0x8B61313BBABCE2C6, 0x2323AC4B3B3DA015,  # 5^-40
    0xAE397D8AA96C1B77, 0xABEC975E0A0D081A,  # 5^-39
    0xD9C7DCED53C72255, 0x96E7BD358C904A21,  # 5^-38
    0x881CEA14545C7575, 0x7E50D64177DA2E54,  # 5^-37
    0xAA242499697392D2, 0xDDE50BD1D5D0B9E9,  # 5^-36
    0xD4AD2DBFC3D07787, 0x955E4EC64B44E864,  # 5^-35
    0x84EC3C97DA624AB4, 0xBD5AF13BEF0B113E,  # 5^-34
    0xA6274BBDD0FADD61, 0xECB1AD8AEACDD58E,  # 5^-33
    0xCFB11EAD453994BA, 0x67DE18EDA5814AF2,  # 5^-32
    0x81CEB32C4B43FCF4, 0x80EACF948770CED7,  # 5^-31
    0xA2425FF75E14FC31, 0xA1258379A94D028D,  # 5^-30
    0xCAD2F7F5359A3B3E, 0x096EE45813A04330,  # 5^-29
    0xFD87B5F28300CA0D, 0x8BCA9D6E188853FC,  # 5^-28
    0x9E74D1B791E07E48, 0x775EA264CF55347E,  # 5^-27
    0xC612062576589DDA, 0x95364AFE032A819E,  # 5^-26
    0xF79687AED3EEC551, 0x3A83DDBD83F52205,  # 5^-25
    0x9ABE14CD44753B52, 0xC4926A9672793543,  # 5^-24
    0xC16D9A0095928A27, 0x75B7053C0F178294,  # 5^-23
    0xF1C90080BAF72CB1, 0x5324C68B12DD6339,  # 5^-22
    0x971DA05074DA7BEE, 0xD3F6FC16EBCA5E04,  # 5^-21
    0xBCE5086492111AEA, 0x88F4BB1CA6BCF585,  # 5^-20
    0xEC1E4A7DB69561A5, 0x2B31E9E3D06C32E6,  # 5^-19
    0x9392EE8E921D5D07, 0x3AFF322E62439FD0,  # 5^-18
    0xB877AA3236A4B449, 0x09BEFEB9FAD487C3,  # 5^-17
    0xE69594BEC44DE15B, 0x4C2EBE687989A9B4,  # 5^-16
    0x901D7CF73AB0ACD9, 0x0F9D37014BF60A11,  # 5^-15
    0xB424DC35095CD80F, 0x538484C19EF38C95,  # 5^-14
    0xE12E13424BB40E13, 0x2865A5F206B06FBA,  # 5^-13
    0x8CBCCC096F5088CB, 0xF93F87B7442E45D4,  # 5^-12
    0xAFEBFF0BCB24AAFE, 0xF78F69A51539D749,  # 5^-11
    0xDBE6FECEBDEDD5BE, 0xB573440E5A884D1C,  # 5^-10
    0x89705F4136B4A597, 0x31680A88F8953031,  # 5^-9
    0xABCC77118461CEFC, 0xFDC20D2B36BA7C3E,  # 5^-8
    0xD6BF94D5E57A42BC, 0x3D32907604691B4D,  # 5^-7
    0x8637BD05AF6C69B5, 0xA63F9A49C2C1B110,  # 5^-6
    0xA7C5AC471B478423, 0x0FCF80DC33721D54,  # 5^-5
    0xD1B71758E219652B, 0xD3C36113404EA4A9,  # 5^-4
    0x83126E978D4FDF3B, 0x645A1CAC083126EA,  # 5^-3
    0xA3D70A3D70A3D70A, 0x3D70A3D70A3D70A4,  # 5^-2
    0xCCCCCCCCCCCCCCCC, 0xCCCCCCCCCCCCCCCD,  # 5^-1
    0x8000000000000000, 0x0000000000000000,  # 5^0
    0xA000000000000000, 0x0000000000000000,  # 5^1
    0xC800000000000000, 0x0000000000000000,  # 5^2
    0xFA00000000000000, 0x0000000000000000,  # 5^3
    0x9C40000000000000, 0x0000000000000000,  # 5^4
    0xC350000000000000, 0x0000000000000000,  # 5^5
    0xF424000000000000, 0x0000000000000000,  # 5^6
    0x9896800000000000, 0x0000000000000000,  # 5^7
    0xBEBC200000000000, 0x0000000000000000,  # 5^8
    0xEE6B280000000000, 0x0000000000000000,  # 5^9
    0x9502F90000000000, 0x0000000000000000,  # 5^10
    0xBA43B74000000000, 0x0000000000000000,  # 5^11
    0xE8D4A51000000000, 0x0000000000000000,  # 5^12
    0x9184E72A00000000, 0x0000000000000000,  # 5^13
    0xB5E620F480000000, 0x0000000000000000,  # 5^14
    0xE35FA931A0000000, 0x0000000000000000,  # 5^15
    0x8E1BC9BF04000000, 0x0000000000000000,  # 5^16
    0xB1A2BC2EC5000000, 0x0000000000000000,  # 5^17
    0xDE0B6B3A76400000, 0x0000000000000000,  # 5^18
    0x8AC7230489E80000, 0x0000000000000000,  # 5^19
    0xAD78EBC5AC620000, 0x0000000000000000,  # 5^20
    0xD8D726B7177A8000, 0x0000000000000000,  # 5^21
    0x878678326EAC9000, 0x0000000000000000,  # 5^22
    0xA968163F0A57B400, 0x0000000000000000,  # 5^23
    0xD3C21BCECCEDA100, 0x0000000000000000,  # 5^24
    0x84595161401484A0, 0x0000000000000000,  # 5^25
    0xA56FA5B99019A5C8, 0x0000000000000000,  # 5^26
    0xCECB8F27F4200F3A, 0x0000000000000000,  # 5^27
    0x813F3978F8940984, 0x4000000000000000,  # 5^28
    0xA18F07D736B90BE5, 0x5000000000000000,  # 5^29
    0xC9F2C9CD04674EDE, 0xA400000000000000,  # 5^30
    0xFC6F7C4045812296, 0x4D00000000000000,  # 5^31
    0x9DC5ADA82B70B59D, 0xF020000000000000,  # 5^32
    0xC5371912364CE305, 0x6C28000000000000,  # 5^33
    0xF684DF56C3E01BC6, 0xC732000000000000,  # 5^34
    0x9A130B963A6C115C, 0x3C7F400000000000,  # 5^35
    0xC097CE7BC90715B3, 0x4B9F100000000000,  # 5^36
    0xF0BDC21ABB48DB20, 0x1E86D40000000000,  # 5^37
    0x96769950B50D88F4, 0x1314448000000000,  # 5^38
    0xBC143FA4E250EB31, 0x17D955A000000000,  # 5^39
    0xEB194F8E1AE525FD, 0x5DCFAB0800000000,  # 5^40
    0x92EFD1B8D0CF37BE, 0x5AA1CAE500000000,  # 5^41
    0xB7ABC627050305AD, 0xF14A3D9E40000000,  # 5^42
    0xE596B7B0C643C719, 0x6D9CCD05D0000000,  # 5^43
    0x8F7E32CE7BEA5C6F, 0xE4820023A2000000,  # 5^44
    0xB35DBF821AE4F38B, 0xDDA2802C8A800000,  # 5^45
    0xE0352F62A19E306E, 0xD50B2037AD200000,  # 5^46
    0x8C213D9DA502DE45, 0x4526F422CC340000,  # 5^47
    0xAF298D050E4395D6, 0x9670B12B7F410000,  # 5^48
    0xDAF3F04651D47B4C, 0x3C0CDD765F114000,  # 5^49
    0x88D8762BF324CD0F, 0xA5880A69FB6AC800,  # 5^50
    0xAB0E93B6EFEE0053, 0x8EEA0D047A457A00,  # 5^51
    0xD5D238A4ABE98068, 0x72A4904598D6D880,  # 5^52
    0x85A36366EB71F041, 0x47A6DA2B7F864750,  # 5^53
    0xA70C3C40A64E6C51, 0x999090B65F67D924,  # 5^54
    0xD0CF4B50CFE20765, 0xFFF4B4E3F741CF6D,  # 5^55
    0x82818F1281ED449F, 0xBFF8F10E7A8921A4,  # 5^56
    0xA321F2D7226895C7, 0xAFF72D52192B6A0D,  # 5^57
    0xCBEA6F8CEB02BB39, 0x9BF4F8A69F764490,  # 5^58
    0xFEE50B7025C36A08, 0x02F236D04753D5B4,  # 5^59
    0x9F4F2726179A2245, 0x01D762422C946590,  # 5^60
    0xC722F0EF9D80AAD6, 0x424D3AD2B7B97EF5,  # 5^61
    0xF8EBAD2B84E0D58B, 0xD2E0898765A7DEB2,  # 5^62
    0x9B934C3B330C8577, 0x63CC55F49F88EB2F,  # 5^63
    0xC2781F49FFCFA6D5, 0x3CBF6B71C76B25FB,  # 5^64
    0xF316271C7FC3908A, 0x8BEF464E3945EF7A,  # 5^65
    0x97EDD871CFDA3A56, 0x97758BF0E3CBB5AC,  # 5^66
    0xBDE94E8E43D0C8EC, 0x3D52EEED1CBEA317,  # 5^67
    0xED63A231D4C4FB27, 0x4CA7AAA863EE4BDD,  # 5^68
    0x945E455F24FB1CF8, 0x8FE8CAA93E74EF6A,  # 5^69
    0xB975D6B6EE39E436, 0xB3E2FD538E122B44,  # 5^70
    0xE7D34C64A9C85D44, 0x60DBBCA87196B616,  # 5^71
    0x90E40FBEEA1D3A4A, 0xBC8955E946FE31CD,  # 5^72
    0xB51D13AEA4A488DD, 0x6BABAB6398BDBE41,  # 5^73
    0xE264589A4DCDAB14, 0xC696963C7EED2DD1,  # 5^74
    0x8D7EB76070A08AEC, 0xFC1E1DE5CF543CA2,  # 5^75
    0xB0DE65388CC8ADA8, 0x3B25A55F43294BCB,  # 5^76
    0xDD15FE86AFFAD912, 0x49EF0EB713F39EBE,  # 5^77
    0x8A2DBF142DFCC7AB, 0x6E3569326C784337,  # 5^78
    0xACB92ED9397BF996, 0x49C2C37F07965404,  # 5^79
    0xD7E77A8F87DAF7FB, 0xDC33745EC97BE906,  # 5^80
    0x86F0AC99B4E8DAFD, 0x69A028BB3DED71A3,  # 5^81
    0xA8ACD7C0222311BC, 0xC40832EA0D68CE0C,  # 5^82
    0xD2D80DB02AABD62B, 0xF50A3FA490C30190,  # 5^83
    0x83C7088E1AAB65DB, 0x792667C6DA79E0FA,  # 5^84
    0xA4B8CAB1A1563F52, 0x577001B891185938,  # 5^85
    0xCDE6FD5E09ABCF26, 0xED4C0226B55E6F86,  # 5^86
    0x80B05E5AC60B6178, 0x544F8158315B05B4,  # 5^87
    0xA0DC75F1778E39D6, 0x696361AE3DB1C721,  # 5^88
    0xC913936DD571C84C, 0x03BC3A19CD1E38E9,  # 5^89
    0xFB5878494ACE3A5F, 0x04AB48A04065C723,  # 5^90
    0x9D174B2DCEC0E47B, 0x62EB0D64283F9C76,  # 5^91
    0xC45D1DF942711D9A, 0x3BA5D0BD324F8394,  # 5^92
    0xF5746577930D6500, 0xCA8F44EC7EE36479,  # 5^93
    0x9968BF6ABBE85F20, 0x7E998B13CF4E1ECB,  # 5^94
    0xBFC2EF456AE276E8, 0x9E3FEDD8C321A67E,  # 5^95
    0xEFB3AB16C59B14A2, 0xC5CFE94EF3EA101E,  # 5^96
    0x95D04AEE3B80ECE5, 0xBBA1F1D158724A12,  # 5^97
    0xBB445DA9CA61281F, 0x2A8A6E45AE8EDC97,  # 5^98
    0xEA1575143CF97226, 0xF52D09D71A3293BD,  # 5^99
    0x924D692CA61BE758, 0x593C2626705F9C56,  # 5^100
    0xB6E0C377CFA2E12E, 0x6F8B2FB00C77836C,  # 5^101
    0xE498F455C38B997A, 0x0B6DFB9C0F956447,  # 5^102
    0x8EDF98B59A373FEC, 0x4724BD4189BD5EAC,  # 5^103
    0xB2977EE300C50FE7, 0x58EDEC91EC2CB657,  # 5^104
    0xDF3D5E9BC0F653E1, 0x2F2967B66737E3ED,  # 5^105
    0x8B865B215899F46C, 0xBD79E0D20082EE74,  # 5^106
    0xAE67F1E9AEC07187, 0xECD8590680A3AA11,  # 5^107
    0xDA01EE641A708DE9, 0xE80E6F4820CC9495,  # 5^108
    0x884134FE908658B2, 0x3109058D147FDCDD,  # 5^109
    0xAA51823E34A7EEDE, 0xBD4B46F0599FD415,  # 5^110
    0xD4E5E2CDC1D1EA96, 0x6C9E18AC7007C91A,  # 5^111
    0x850FADC09923329E, 0x03E2CF6BC604DDB0,  # 5^112
    0xA6539930BF6BFF45, 0x84DB8346B786151C,  # 5^113
    0xCFE87F7CEF46FF16, 0xE612641865679A63,  # 5^114
    0x81F14FAE158C5F6E, 0x4FCB7E8F3F60C07E,  # 5^115
    0xA26DA3999AEF7749, 0xE3BE5E330F38F09D,  # 5^116
    0xCB090C8001AB551C, 0x5CADF5BFD3072CC5,  # 5^117
    0xFDCB4FA002162A63, 0x73D9732FC7C8F7F6,  # 5^118
    0x9E9F11C4014DDA7E, 0x2867E7FDDCDD9AFA,  # 5^119
    0xC646D63501A1511D, 0xB281E1FD541501B8,  # 5^120
    0xF7D88BC24209A565, 0x1F225A7CA91A4226,  # 5^121
    0x9AE757596946075F, 0x3375788DE9B06958,  # 5^122
    0xC1A12D2FC3978937, 0x0052D6B1641C83AE,  # 5^123
    0xF209787BB47D6B84, 0xC0678C5DBD23A49A,  # 5^124
    0x9745EB4D50CE6332, 0xF840B7BA963646E0,  # 5^125
    0xBD176620A501FBFF, 0xB650E5A93BC3D898,  # 5^126
    0xEC5D3FA8CE427AFF, 0xA3E51F138AB4CEBE,  # 5^127
    0x93BA47C980E98CDF, 0xC66F336C36B10137,  # 5^128
    0xB8A8D9BBE123F017, 0xB80B0047445D4184,  # 5^129
    0xE6D3102AD96CEC1D, 0xA60DC059157491E5,  # 5^130
    0x9043EA1AC7E41392, 0x87C89837AD68DB2F,  # 5^131
    0xB454E4A179DD1877, 0x29BABE4598C311FB,  # 5^132
    0xE16A1DC9D8545E94, 0xF4296DD6FEF3D67A,  # 5^133
    0x8CE2529E2734BB1D, 0x1899E4A65F58660C,  # 5^134
    0xB01AE745B101E9E4, 0x5EC05DCFF72E7F8F,  # 5^135
    0xDC21A1171D42645D, 0x76707543F4FA1F73,  # 5^136
    0x899504AE72497EBA, 0x6A06494A791C53A8,  # 5^137
    0xABFA45DA0EDBDE69, 0x0487DB9D17636892,  # 5^138
    0xD6F8D7509292D603, 0x45A9D2845D3C42B6,  # 5^139
    0x865B86925B9BC5C2, 0x0B8A2392BA45A9B2,  # 5^140
    0xA7F26836F282B732, 0x8E6CAC7768D7141E,  # 5^141
    0xD1EF0244AF2364FF, 0x3207D795430CD926,  # 5^142
    0x8335616AED761F1F, 0x7F44E6BD49E807B8,  # 5^143
    0xA402B9C5A8D3A6E7, 0x5F16206C9C6209A6,  # 5^144
    0xCD036837130890A1, 0x36DBA887C37A8C0F,  # 5^145
    0x802221226BE55A64, 0xC2494954DA2C9789,  # 5^146
    0xA02AA96B06DEB0FD, 0xF2DB9BAA10B7BD6C,  # 5^147
    0xC83553C5C8965D3D, 0x6F92829494E5ACC7,  # 5^148
    0xFA42A8B73ABBF48C, 0xCB772339BA1F17F9,  # 5^149
    0x9C69A97284B578D7, 0xFF2A760414536EFB,  # 5^150
    0xC38413CF25E2D70D, 0xFEF5138519684ABA,  # 5^151
    0xF46518C2EF5B8CD1, 0x7EB258665FC25D69,  # 5^152
    0x98BF2F79D5993802, 0xEF2F773FFBD97A61,  # 5^153
    0xBEEEFB584AFF8603, 0xAAFB550FFACFD8FA,  # 5^154
    0xEEAABA2E5DBF6784, 0x95BA2A53F983CF38,  # 5^155
    0x952AB45CFA97A0B2, 0xDD945A747BF26183,  # 5^156
    0xBA756174393D88DF, 0x94F971119AEEF9E4,  # 5^157
    0xE912B9D1478CEB17, 0x7A37CD5601AAB85D,  # 5^158
    0x91ABB422CCB812EE, 0xAC62E055C10AB33A,  # 5^159
    0xB616A12B7FE617AA, 0x577B986B314D6009,  # 5^160
    0xE39C49765FDF9D94, 0xED5A7E85FDA0B80B,  # 5^161
    0x8E41ADE9FBEBC27D, 0x14588F13BE847307,  # 5^162
    0xB1D219647AE6B31C, 0x596EB2D8AE258FC8,  # 5^163
    0xDE469FBD99A05FE3, 0x6FCA5F8ED9AEF3BB,  # 5^164
    0x8AEC23D680043BEE, 0x25DE7BB9480D5854,  # 5^165
    0xADA72CCC20054AE9, 0xAF561AA79A10AE6A,  # 5^166
    0xD910F7FF28069DA4, 0x1B2BA1518094DA04,  # 5^167
    0x87AA9AFF79042286, 0x90FB44D2F05D0842,  # 5^168
    0xA99541BF57452B28, 0x353A1607AC744A53,  # 5^169
    0xD3FA922F2D1675F2, 0x42889B8997915CE8,  # 5^170
    0x847C9B5D7C2E09B7, 0x69956135FEBADA11,  # 5^171
    0xA59BC234DB398C25, 0x43FAB9837E699095,  # 5^172
    0xCF02B2C21207EF2E, 0x94F967E45E03F4BB,  # 5^173
    0x8161AFB94B44F57D, 0x1D1BE0EEBAC278F5,  # 5^174
    0xA1BA1BA79E1632DC, 0x6462D92A69731732,  # 5^175
    0xCA28A291859BBF93, 0x7D7B8F7503CFDCFE,  # 5^176
    0xFCB2CB35E702AF78, 0x5CDA735244C3D43E,  # 5^177
    0x9DEFBF01B061ADAB, 0x3A0888136AFA64A7,  # 5^178
    0xC56BAEC21C7A1916, 0x088AAA1845B8FDD0,  # 5^179
    0xF6C69A72A3989F5B, 0x8AAD549E57273D45,  # 5^180
    0x9A3C2087A63F6399, 0x36AC54E2F678864B,  # 5^181
    0xC0CB28A98FCF3C7F, 0x84576A1BB416A7DD,  # 5^182
    0xF0FDF2D3F3C30B9F, 0x656D44A2A11C51D5,  # 5^183
    0x969EB7C47859E743, 0x9F644AE5A4B1B325,  # 5^184
    0xBC4665B596706114, 0x873D5D9F0DDE1FEE,  # 5^185
    0xEB57FF22FC0C7959, 0xA90CB506D155A7EA,  # 5^186
    0x9316FF75DD87CBD8, 0x09A7F12442D588F2,  # 5^187
    0xB7DCBF5354E9BECE, 0x0C11ED6D538AEB2F,  # 5^188
    0xE5D3EF282A242E81, 0x8F1668C8A86DA5FA,  # 5^189
    0x8FA475791A569D10, 0xF96E017D694487BC,  # 5^190
    0xB38D92D760EC4455, 0x37C981DCC395A9AC,  # 5^191
    0xE070F78D3927556A, 0x85BBE253F47B1417,  # 5^192
    0x8C469AB843B89562, 0x93956D7478CCEC8E,  # 5^193
    0xAF58416654A6BABB, 0x387AC8D1970027B2,  # 5^194
    0xDB2E51BFE9D0696A, 0x06997B05FCC0319E,  # 5^195
    0x88FCF317F22241E2, 0x441FECE3BDF81F03,  # 5^196
    0xAB3C2FDDEEAAD25A, 0xD527E81CAD7626C3,  # 5^197
    0xD60B3BD56A5586F1, 0x8A71E223D8D3B074,  # 5^198
    0x85C7056562757456, 0xF6872D5667844E49,  # 5^199
    0xA738C6BEBB12D16C, 0xB428F8AC016561DB,  # 5^200
    0xD106F86E69D785C7, 0xE13336D701BEBA52,  # 5^201
    0x82A45B450226B39C, 0xECC0024661173473,  # 5^202
    0xA34D721642B06084, 0x27F002D7F95D0190,  # 5^203
    0xCC20CE9BD35C78A5, 0x31EC038DF7B441F4,  # 5^204
    0xFF290242C83396CE, 0x7E67047175A15271,  # 5^205
    0x9F79A169BD203E41, 0x0F0062C6E984D386,  # 5^206
    0xC75809C42C684DD1, 0x52C07B78A3E60868,  # 5^207
    0xF92E0C3537826145, 0xA7709A56CCDF8A82,  # 5^208
    0x9BBCC7A142B17CCB, 0x88A66076400BB691,  # 5^209
    0xC2ABF989935DDBFE, 0x6ACFF893D00EA435,  # 5^210
    0xF356F7EBF83552FE, 0x0583F6B8C4124D43,  # 5^211
    0x98165AF37B2153DE, 0xC3727A337A8B704A,  # 5^212
    0xBE1BF1B059E9A8D6, 0x744F18C0592E4C5C,  # 5^213
    0xEDA2EE1C7064130C, 0x1162DEF06F79DF73,  # 5^214
    0x9485D4D1C63E8BE7, 0x8ADDCB5645AC2BA8,  # 5^215
    0xB9A74A0637CE2EE1, 0x6D953E2BD7173692,  # 5^216
    0xE8111C87C5C1BA99, 0xC8FA8DB6CCDD0437,  # 5^217
    0x910AB1D4DB9914A0, 0x1D9C9892400A22A2,  # 5^218
    0xB54D5E4A127F59C8, 0x2503BEB6D00CAB4B,  # 5^219
    0xE2A0B5DC971F303A, 0x2E44AE64840FD61D,  # 5^220
    0x8DA471A9DE737E24, 0x5CEAECFED289E5D2,  # 5^221
    0xB10D8E1456105DAD, 0x7425A83E872C5F47,  # 5^222
    0xDD50F1996B947518, 0xD12F124E28F77719,  # 5^223
    0x8A5296FFE33CC92F, 0x82BD6B70D99AAA6F,  # 5^224
    0xACE73CBFDC0BFB7B, 0x636CC64D1001550B,  # 5^225
    0xD8210BEFD30EFA5A, 0x3C47F7E05401AA4E,  # 5^226
    0x8714A775E3E95C78, 0x65ACFAEC34810A71,  # 5^227
    0xA8D9D1535CE3B396, 0x7F1839A741A14D0D,  # 5^228
    0xD31045A8341CA07C, 0x1EDE48111209A050,  # 5^229
    0x83EA2B892091E44D, 0x934AED0AAB460432,  # 5^230
    0xA4E4B66B68B65D60, 0xF81DA84D5617853F,  # 5^231
    0xCE1DE40642E3F4B9, 0x36251260AB9D668E,  # 5^232
    0x80D2AE83E9CE78F3, 0xC1D72B7C6B426019,  # 5^233
    0xA1075A24E4421730, 0xB24CF65B8612F81F,  # 5^234
    0xC94930AE1D529CFC, 0xDEE033F26797B627,  # 5^235
    0xFB9B7CD9A4A7443C, 0x169840EF017DA3B1,  # 5^236
    0x9D412E0806E88AA5, 0x8E1F289560EE864E,  # 5^237
    0xC491798A08A2AD4E, 0xF1A6F2BAB92A27E2,  # 5^238
    0xF5B5D7EC8ACB58A2, 0xAE10AF696774B1DB,  # 5^239
    0x9991A6F3D6BF1765, 0xACCA6DA1E0A8EF29,  # 5^240
    0xBFF610B0CC6EDD3F, 0x17FD090A58D32AF3,  # 5^241
    0xEFF394DCFF8A948E, 0xDDFC4B4CEF07F5B0,  # 5^242
    0x95F83D0A1FB69CD9, 0x4ABDAF101564F98E,  # 5^243
    0xBB764C4CA7A4440F, 0x9D6D1AD41ABE37F1,  # 5^244
    0xEA53DF5FD18D5513, 0x84C86189216DC5ED,  # 5^245
    0x92746B9BE2F8552C, 0x32FD3CF5B4E49BB4,  # 5^246
    0xB7118682DBB66A77, 0x3FBC8C33221DC2A1,  # 5^247
    0xE4D5E82392A40515, 0x0FABAF3FEAA5334A,  # 5^248
    0x8F05B1163BA6832D, 0x29CB4D87F2A7400E,  # 5^249
    0xB2C71D5BCA9023F8, 0x743E20E9EF511012,  # 5^250
    0xDF78E4B2BD342CF6, 0x914DA9246B255416,  # 5^251
    0x8BAB8EEFB6409C1A, 0x1AD089B6C2F7548E,  # 5^252
    0xAE9672ABA3D0C320, 0xA184AC2473B529B1,  # 5^253
    0xDA3C0F568CC4F3E8, 0xC9E5D72D90A2741E,  # 5^254
    0x8865899617FB1871, 0x7E2FA67C7A658892,  # 5^255
    0xAA7EEBFB9DF9DE8D, 0xDDBB901B98FEEAB7,  # 5^256
    0xD51EA6FA85785631, 0x552A74227F3EA565,  # 5^257
    0x8533285C936B35DE, 0xD53A88958F87275F,  # 5^258
    0xA67FF273B8460356, 0x8A892ABAF368F137,  # 5^259
    0xD01FEF10A657842C, 0x2D2B7569B0432D85,  # 5^260
    0x8213F56A67F6B29B, 0x9C3B29620E29FC73,  # 5^261
    0xA298F2C501F45F42, 0x8349F3BA91B47B8F,  # 5^262
    0xCB3F2F7642717713, 0x241C70A936219A73,  # 5^263
    0xFE0EFB53D30DD4D7, 0xED238CD383AA0110,  # 5^264
    0x9EC95D1463E8A506, 0xF4363804324A40AA,  # 5^265
    0xC67BB4597CE2CE48, 0xB143C6053EDCD0D5,  # 5^266
    0xF81AA16FDC1B81DA, 0xDD94B7868E94050A,  # 5^267
    0x9B10A4E5E9913128, 0xCA7CF2B4191C8326,  # 5^268
    0xC1D4CE1F63F57D72, 0xFD1C2F611F63A3F0,  # 5^269
    0xF24A01A73CF2DCCF, 0xBC633B39673C8CEC,  # 5^270
    0x976E41088617CA01, 0xD5BE0503E085D813,  # 5^271
    0xBD49D14AA79DBC82, 0x4B2D8644D8A74E18,  # 5^272
    0xEC9C459D51852BA2, 0xDDF8E7D60ED1219E,  # 5^273
    0x93E1AB8252F33B45, 0xCABB90E5C942B503,  # 5^274
    0xB8DA1662E7B00A17, 0x3D6A751F3B936243,  # 5^275
    0xE7109BFBA19C0C9D, 0x0CC512670A783AD4,  # 5^276
    0x906A617D450187E2, 0x27FB2B80668B24C5,  # 5^277
    0xB484F9DC9641E9DA, 0xB1F9F660802DEDF6,  # 5^278
    0xE1A63853BBD26451, 0x5E7873F8A0396973,  # 5^279
    0x8D07E33455637EB2, 0xDB0B487B6423E1E8,  # 5^280
    0xB049DC016ABC5E5F, 0x91CE1A9A3D2CDA62,  # 5^281
    0xDC5C5301C56B75F7, 0x7641A140CC7810FB,  # 5^282
    0x89B9B3E11B6329BA, 0xA9E904C87FCB0A9D,  # 5^283
    0xAC2820D9623BF429, 0x546345FA9FBDCD44,  # 5^284
    0xD732290FBACAF133, 0xA97C177947AD4095,  # 5^285
    0x867F59A9D4BED6C0, 0x49ED8EABCCCC485D,  # 5^286
    0xA81F301449EE8C70, 0x5C68F256BFFF5A74,  # 5^287
    0xD226FC195C6A2F8C, 0x73832EEC6FFF3111,  # 5^288
    0x83585D8FD9C25DB7, 0xC831FD53C5FF7EAB,  # 5^289
    0xA42E74F3D032F525, 0xBA3E7CA8B77F5E55,  # 5^290
    0xCD3A1230C43FB26F, 0x28CE1BD2E55F35EB,  # 5^291
    0x80444B5E7AA7CF85, 0x7980D163CF5B81B3,  # 5^292
    0xA0555E361951C366, 0xD7E105BCC332621F,  # 5^293
    0xC86AB5C39FA63440, 0x8DD9472BF3FEFAA7,  # 5^294
    0xFA856334878FC150, 0xB14F98F6F0FEB951,  # 5^295
    0x9C935E00D4B9D8D2, 0x6ED1BF9A569F33D3,  # 5^296
    0xC3B8358109E84F07, 0x0A862F80EC4700C8,  # 5^297
    0xF4A642E14C6262C8, 0xCD27BB612758C0FA,  # 5^298
    0x98E7E9CCCFBD7DBD, 0x8038D51CB897789C,  # 5^299
    0xBF21E44003ACDD2C, 0xE0470A63E6BD56C3,  # 5^300
    0xEEEA5D5004981478, 0x1858CCFCE06CAC74,  # 5^301
    0x95527A5202DF0CCB, 0x0F37801E0C43EBC8,  # 5^302
    0xBAA718E68396CFFD, 0xD30560258F54E6BA,  # 5^303
    0xE950DF20247C83FD, 0x47C6B82EF32A2069,  # 5^304
    0x91D28B7416CDD27E, 0x4CDC331D57FA5441,  # 5^305
    0xB6472E511C81471D, 0xE0133FE4ADF8E952,  # 5^306
    0xE3D8F9E563A198E5, 0x58180FDDD97723A6,  # 5^307
    0x8E679C2F5E44FF8F, 0x570F09EAA7EA7648,  # 5^308
]
comptime _SCHUBFACH_G: InlineArray[UInt64, 1234] = [
    0x4F0CEDC95A718DD4, 0x5B01E8B09AA0D1B5,  # k = -324
    0x7E7B160EF71C1621, 0x119CA780F767B5EE,  # k = -323
    0x652F44D8C5B011B4, 0x0E16EC672C52F7F2,  # k = -322
    0x50F29D7A37C00E29, 0x581256B8F0425FF5,  # k = -321
    0x40C21794F96671BA, 0x79A84560C0351991,  # k = -320
    0x679CF287F570B5F7, 0x75DA089ACD21C281,  # k = -319
    0x52E3F5399126F7F9, 0x44AE6D48A41B0201,  # k = -318
    0x424FF76140EBF994, 0x36F1F106E9AF34CD,  # k = -317
    0x6A198BCECE465C20, 0x57E981A4A918547B,  # k = -316
    0x54E13CA571D1E34D, 0x2CBACE1D541376C9,  # k = -315
    0x43E763B78E4182A4, 0x23C8A4E44342C56E,  # k = -314
    0x6CA56C58E39C043A, 0x060DD4A06B9E08B0,  # k = -313
    0x56EABD13E9499CFB, 0x1E7176E6BC7E6D59,  # k = -312
    0x458897432107B0C8, 0x7EC12BEBC9FEBDE1,  # k = -311
    0x6F40F20501A5E7A7, 0x7E01DFDFA9979635,  # k = -310
    0x5900C19D9AEB1FB9, 0x4B34B319547944F7,  # k = -309
    0x4733CE17AF227FC7, 0x55C3C27AA9FA9D93,  # k = -308
    0x71EC7CF2B1D0CC72, 0x560603F7765DC8EA,  # k = -307
    0x5B2397288E40A38E, 0x7804CFF92B7E3A55,  # k = -306
    0x48E945BA0B66E93F, 0x13370CC755FE9511,  # k = -305
    0x74A86F90123E41FE, 0x51F1AE0BBCCA881B,  # k = -304
    0x5D538C7341CB67FE, 0x74C1580963D539AF,  # k = -303
    0x4AA93D29016F8665, 0x43CDE0078310FAF3,  # k = -302
    0x77752EA8024C0A3C, 0x0616333F381B2B1E,  # k = -301
    0x5F90F22001D66E96, 0x3811C298F9AF55B1,  # k = -300
    0x4C73F4E667DEBEDE, 0x600E35472E25DE28,  # k = -299
    0x7A532170A6313164, 0x3349EED849D6303F,  # k = -298
    0x61DC1AC084F42783, 0x42A18BE03B11C033,  # k = -297
    0x4E49AF006A5CEC69, 0x1BB46FE695A7CCF5,  # k = -296
    0x7D42B19A43C7E0A8, 0x2C53E63DBC3FAE55,  # k = -295
    0x64355AE1CFD31A20, 0x237651CAFCFFBEAA,  # k = -294
    0x502AAF1B0CA8E1B3, 0x35F8416F30CC9888,  # k = -293
    0x402225AF3D53E7C2, 0x5E603458F3D6E06D,  # k = -292
    0x669D0918621FD937, 0x4A3386F4B957CD7B,  # k = -291
    0x52173A79E8197A92, 0x6E8F9F2A2DDFD796,  # k = -290
    0x41AC2EC7ECE12EDB, 0x720C7F54F17FDFAB,  # k = -289
    0x69137E0CAE3517C6, 0x1CE0CBBB1BFFCC45,  # k = -288
    0x540F980A24F74638, 0x171A3C95AFFFD69E,  # k = -287
    0x433FACD4EA5F6B60, 0x127B63AAF3331218,  # k = -286
    0x6B991487DD657899, 0x6A5F05DE51EB5026,  # k = -285
    0x5614106CB11DFA14, 0x5518D17EA7EF7352,  # k = -284
    0x44DCD9F08DB194DD, 0x2A7A41321FF2C2A8,  # k = -283
    0x6E2E2980E2B5BAFB, 0x5D906850331E043F,  # k = -282
    0x5824EE00B55E2F2F, 0x647386A68F4B3699,  # k = -281
    0x4683F19A2AB1BF59, 0x36C2D21ED908F87B,  # k = -280
    0x70D31C29DDE93228, 0x579E1CFE280E5A5D,  # k = -279
    0x5A427CEE4B20F4ED, 0x2C7E7D98200B7B7E,  # k = -278
    0x483530BEA280C3F1, 0x09FECAE019A2C932,  # k = -277
    0x73884DFDD0CE064E, 0x43314499C29E0EB6,  # k = -276
    0x5C6D0B3173D8050B, 0x4F5A9D47CEE4D891,  # k = -275
    0x49F0D5C129799DA2, 0x72AEE4397250AD41,  # k = -274
    0x764E22CEA8C295D1, 0x377E39F583B44868,  # k = -273
    0x5EA4E8A553CEDE41, 0x12CB61913629D387,  # k = -272
    0x4BB72084430BE500, 0x756F8140F8217605,  # k = -271
    0x792500D39E796E67, 0x6F18CECE59CF233C,  # k = -270
    0x60EA670FB1FABEB9, 0x3F470BD847D8E8FD,  # k = -269
    0x4D885272F4C89894, 0x329F3CAD064720CA,  # k = -268
    0x7C0D50B7EE0DC0ED, 0x37652DE1A3A50143,  # k = -267
    0x633DDA2CBE716724, 0x2C50F1814FB73436,  # k = -266
    0x4F64AE8A31F45283, 0x3D0D8E010C92902B,  # k = -265
    0x7F077DA9E986EA6B, 0x7B48E334E0EA8045,  # k = -264
    0x659F97BB2138BB89, 0x49071C2A4D88669D,  # k = -263
    0x514C796280FA2FA1, 0x20D27CEEA46D1EE4,  # k = -262
    0x4109FAB533FB594D, 0x670ECA58838A7F1D,  # k = -261
    0x680FF788532BC216, 0x0B4ADD5A6C10CB62,  # k = -260
    0x533FF939DC2301AB, 0x22A24AAEBCDA3C4E,  # k = -259
    0x4299942E49B59AEF, 0x354EA22563E1C9D8,  # k = -258
    0x6A8F537D42BC2B18, 0x554A9D089FCFA95A,  # k = -257
    0x553F75FDCEFCEF46, 0x776EE406E63FBAAE,  # k = -256
    0x4432C4CB0BFD8C38, 0x5F8BE99F1E996225,  # k = -255
    0x6D1E07AB466279F4, 0x327975CB64289D08,  # k = -254
    0x574B3955D1E86190, 0x28612B091CED4A6D,  # k = -253
    0x45D5C777DB204E0D, 0x06B4226DB0BDD524,  # k = -252
    0x6FBC72595E9A167B, 0x24536A491AC95506,  # k = -251
    0x59638EADE54811FC, 0x1D0F883A7BD44405,  # k = -250
    0x4782D88B1DD34196, 0x4A72D361FCA9D004,  # k = -249
    0x726AF411C952028A, 0x43EAEBCFFAA94CD3,  # k = -248
    0x5B88C3416DDB353B, 0x4FEF230CC88770A9,  # k = -247
    0x493A35CDF17C2A96, 0x0CBF4F3D6D3926EE,  # k = -246
    0x7529EFAFE8C6AA89, 0x61321862485B717C,  # k = -245
    0x5DBB262653D22207, 0x675B46B506AF8DFD,  # k = -244
    0x4AFC1E850FDB4E6C, 0x52AF6BC405593E64,  # k = -243
    0x77F9CA6E7FC54A47, 0x377F12D33BC1FD6D,  # k = -242
    0x5FFB085866376E9F, 0x45FF42429634CABD,  # k = -241
    0x4CC8D379EB5F8BB2, 0x6B329B68782A3BCB,  # k = -240
    0x7ADAEBF64565AC51, 0x2B842BDA59DD2C77,  # k = -239
    0x6248BCC5045156A7, 0x3C69BCAEAE4A89F9,  # k = -238
    0x4EA0970403744552, 0x6387CA25583BA194,  # k = -237
    0x7DCDBE6CD253A21E, 0x05A6103BC05F68ED,  # k = -236
    0x64A498570EA94E7E, 0x37B80CFC99E5ED8A,  # k = -235
    0x5083AD1272210B98, 0x2C933D96E184BE08,  # k = -234
    0x40695741F4E73C79, 0x7075CADF1AD09807,  # k = -233
    0x670EF2032171FA5C, 0x4D8944982AE759A4,  # k = -232
    0x52725B35B45B2EB0, 0x3E076A135585E150,  # k = -231
    0x41F515C49048F226, 0x64D2BB42AAD1810D,  # k = -230
    0x698822D41A0E503E, 0x07B7920444826815,  # k = -229
    0x546CE8A9AE71D9CB, 0x1FC60E69D0685344,  # k = -228
    0x438A53BAF1F4AE3C, 0x196B3EBB0D20429D,  # k = -227
    0x6C1085F7E9877D2D, 0x0F11FDF815006A94,  # k = -226
    0x56739E5FEE05FDBD, 0x58DB319344005543,  # k = -225
    0x45294B7FF19E6497, 0x60AF5ADC3666AA9C,  # k = -224
    0x6EA878CCB5CA3A8C, 0x344BC4938A3DDDC7,  # k = -223
    0x5886C70A2B082ED6, 0x5D096A0FA1CB17D2,  # k = -222
    0x46D238D4EF39BF12, 0x173ABB3FB4A27975,  # k = -221
    0x71505AEE4B8F981D, 0x0B912B992103F588,  # k = -220
    0x5AA6AF25093FACE4, 0x0940EFADB4032AD3,  # k = -219
    0x488558EA6DCC8A50, 0x07672624900288A9,  # k = -218
    0x74088E43E2E0DD4C, 0x723EA36DB337410E,  # k = -217
    0x5CD3A5031BE71770, 0x5B654F8AF5C5CDA5,  # k = -216
    0x4A42EA68E31F45F3, 0x62B772D5916B0AEB,  # k = -215
    0x76D1770E38320986, 0x0458B7BC1BDE77DD,  # k = -214
    0x5F0DF8D82CF4D46B, 0x1D13C630164B9318,  # k = -213
    0x4C0B2D79BD90A9EF, 0x30DC9E8CDEA2DC13,  # k = -212
    0x79AB7BF5FC1AA97F, 0x0160FDAE31049351,  # k = -211
    0x6155FCC4C9AEEDFF, 0x1AB3FE24F403A90E,  # k = -210
    0x4DDE63D0A158BE65, 0x6229981D9002EDA5,  # k = -209
    0x7C97061A9BC130A2, 0x69DC2695B337E2A1,  # k = -208
    0x63AC04E2163426E8, 0x54B01EDE28F9821B,  # k = -207
    0x4FBCD0B4DE901F20, 0x43C018B1BA6134E2,  # k = -206
    0x7F9481216419CB67, 0x1F99C11C5D68549D,  # k = -205
    0x6610674DE9AE3C52, 0x4C7B00E37DED107E,  # k = -204
    0x51A6B90B21583042, 0x09FC00B5FE574065,  # k = -203
    0x41522DA2811359CE, 0x3B3000919845CD1D,  # k = -202
    0x68837C3734EBC2E3, 0x784CCDB5C06FAE95,  # k = -201
    0x539C635F5D8968B6, 0x2D0A3E2B00595877,  # k = -200
    0x42E382B2B13ABA2B, 0x3DA1CB5599E11393,  # k = -199
    0x6B059DEAB52AC378, 0x629C7888F634EC1E,  # k = -198
    0x559E17EEF755692D, 0x3549FA072B5D89B1,  # k = -197
    0x447E798BF91120F1, 0x1107FB38EF7E07C1,  # k = -196
    0x6D9728DFF4E834B5, 0x01A65EC17F300C68,  # k = -195
    0x57AC20B32A535D5D, 0x4E1EB23465C009ED,  # k = -194
    0x46234D5C21DC4AB1, 0x24E55B5D1E333B24,  # k = -193
    0x70387BC69C93AAB5, 0x216EF894FD1EC506,  # k = -192
    0x59C6C96BB076222A, 0x4DF2607730E56A6C,  # k = -191
    0x47D23ABC8D2B4E88, 0x3E5B805F5A5121F0,  # k = -190
    0x72E9F79415121740, 0x63C59A322A1B697F,  # k = -189
    0x5BEE5FA9AA74DF67, 0x03047B5B54E2BACC,  # k = -188
    0x498B7FBAEEC3E5EC, 0x0269FC4910B5623D,  # k = -187
    0x75ABFF917E063CAC, 0x6A432D41B45569FB,  # k = -186
    0x5E2332DACB38308A, 0x21CF5767C37787FC,  # k = -185
    0x4B4F5BE23C2CF3A1, 0x67D912B9692C6CCA,  # k = -184
    0x787EF969F9E185CF, 0x595B5128A8471476,  # k = -183
    0x60659454C7E79E3F, 0x6115DA86ED05A9F8,  # k = -182
    0x4D1E1043D31FB1CC, 0x4DAB1538BD9E2193,  # k = -181
    0x7B634D3951CC4FAD, 0x62AB552795C9CF52,  # k = -180
    0x62B5D7610E3D0C8B, 0x0222AA86116E3F75,  # k = -179
    0x4EF7DF80D830D6D5, 0x4E822204DABE992A,  # k = -178
    0x7E59659AF38157BC, 0x17369CD49130F510,  # k = -177
    0x65145148C2CDDFC9, 0x5F5EE3DD40F3F740,  # k = -176
    0x50DD0DD3CF0B196E, 0x1918B64A9A5CC5CD,  # k = -175
    0x40B0D7DCA5A27ABE, 0x4746F83BAEB09E3E,  # k = -174
    0x678159610903F797, 0x253E59F91780FD2F,  # k = -173
    0x52CDE11A6D9CC612, 0x50FEAE60DF9A6426,  # k = -172
    0x423E4DAEBE1704DB, 0x5A65584D7FAEB685,  # k = -171
    0x69FD4917968B3AF9, 0x10A226E265E4573B,  # k = -170
    0x54CAA0DFABA29594, 0x0D4E8581EB1D1295,  # k = -169
    0x43D54D7FBC821143, 0x243ED134BC174211,  # k = -168
    0x6C887BFF94034ED2, 0x06CAE85460253682,  # k = -167
    0x56D396661002A574, 0x6BD586A9E6842B9B,  # k = -166
    0x457611EB40021DF7, 0x09779EEE52035616,  # k = -165
    0x6F234FDECCD02FF1, 0x5BF297E3B66BBCEF,  # k = -164
    0x58E90CB23D73598E, 0x165BACB62B8963F3,  # k = -163
    0x4720D6F4FDF5E13E, 0x451623C4EFA11CC2,  # k = -162
    0x71CE24BB2FEFCECA, 0x3B569FA17F682E03,  # k = -161
    0x5B0B5095BFF30BD5, 0x15DEE61ACC535803,  # k = -160
    0x48D5DA11665C0977, 0x2B18B8157042ACCF,  # k = -159
    0x74895CE8A3C6758B, 0x5E8DF355806AAE18,  # k = -158
    0x5D3AB0BA1C9EC46F, 0x653E5C4466BBBE7A,  # k = -157
    0x4A955A2E7D4BD059, 0x3765169D1EFC9861,  # k = -156
    0x77555D172EDFB3C2, 0x256E8A94FE60F3CF,  # k = -155
    0x5F777DAC257FC301, 0x6ABED543FEB3F63F,  # k = -154
    0x4C5F97BCEACC9C01, 0x3BCBDDCFFEF65E99,  # k = -153
    0x7A328C6177ADC668, 0x5FAC961997F0975B,  # k = -152
    0x61C209E792F16B86, 0x7FBD44E1465A12AF,  # k = -151
    0x4E34D4B9425ABC6B, 0x7FCA9D810514DBBF,  # k = -150
    0x7D21545B9D5DFA46, 0x32DDC8CE6E87C5FF,  # k = -149
    0x641AA9E2E44B2E9E, 0x5BE4A0A525396B32,  # k = -148
    0x501554B5836F587E, 0x7CB6E6EA842DEF5C,  # k = -147
    0x4011109135F2AD32, 0x30925255368B25E3,  # k = -146
    0x6681B41B89844850, 0x4DB6EA21F0DEA304,  # k = -145
    0x52015CE2D469D373, 0x57C5881B2718826A,  # k = -144
    0x419AB0B576BB0F8F, 0x5FD139AF527A01EF,  # k = -143
    0x68F781225791B27F, 0x4C81F5E550C3364A,  # k = -142
    0x53F9341B79415B99, 0x239B2B1DDA35C508,  # k = -141
    0x432DC3492DCDE2E1, 0x02E288E4AE916A6D,  # k = -140
    0x6B7C6BA849496B01, 0x516A74A1174F10AE,  # k = -139
    0x55FD22ED076DEF34, 0x4121F6E745D8DA25,  # k = -138
    0x44CA82573924BF5D, 0x1A8192529E4714EB,  # k = -137
    0x6E10D08B8EA1322E, 0x5D9C1D50FD3E87DD,  # k = -136
    0x580D73A2D880F4F2, 0x17B01773FDCB9FE4,  # k = -135
    0x4671294F139A5D8E, 0x4626792997D61984,  # k = -134
    0x70B50EE4EC2A2F4A, 0x3D0A5B75BFBCF59F,  # k = -133
    0x5A2A7250BCEE8C3B, 0x4A6EAF916630C47F,  # k = -132
    0x4821F50D63F209C9, 0x21F2260DEB5A36CC,  # k = -131
    0x736988156CB6760E, 0x69837016455D247A,  # k = -130
    0x5C546CDDF091F80B, 0x6E02C011D1175062,  # k = -129
    0x49DD23E4C074C66F, 0x719BCCDB0DAC404E,  # k = -128
    0x762E9FD467213D7F, 0x68F947C4E2AD33B0,  # k = -127
    0x5E8BB3105280FDFF, 0x6D94396A4EF0F627,  # k = -126
    0x4BA2F5A6A8673199, 0x3E102DEEA58D91B9,  # k = -125
    0x7904BC3DDA3EB5C2, 0x3019E3176F48E927,  # k = -124
    0x60D09697E1CBC49B, 0x4014B5AC590720EC,  # k = -123
    0x4D73ABACB4A303AF, 0x4CDD5E237A6C1A57,  # k = -122
    0x7BEC45E12104D2B2, 0x47C8969F2A46908A,  # k = -121
    0x63236B1A80D0A88E, 0x6CA0787F5505406F,  # k = -120
    0x4F4F88E200A6ED3F, 0x0A19F9FF773766BF,  # k = -119
    0x7EE5A7D0010B1531, 0x5CF65CCBF1F23DFE,  # k = -118
    0x6584864000D5AA8E, 0x172B7D6FF4C1CB32,  # k = -117
    0x5136D1CCCD77BBA4, 0x78EF978CC3CE3C28,  # k = -116
    0x40F8A7D70AC62FB7, 0x13F2DFA3CFD83020,  # k = -115
    0x67F43FBE77A37F8B, 0x398499061959E699,  # k = -114
    0x5329CC985FB5FFA2, 0x6136E0D1ADE18548,  # k = -113
    0x4287D6E04C91994F, 0x00F8B3DAF181376D,  # k = -112
    0x6A72F166E0E8F54B, 0x1B27862B1C01F247,  # k = -111
    0x5528C11F1A53F76F, 0x2F52D1BC1667F506,  # k = -110
    0x44209A7F48432C59, 0x0C424163451FF738,  # k = -109
    0x6D00F7320D3846F4, 0x7A039BD208332526,  # k = -108
    0x5733F8F4D76038C3, 0x7B361641A028EA85,  # k = -107
    0x45C32D90AC4CFA36, 0x2F5E78348020BB9E,  # k = -106
    0x6F9EAF4DE07B29F0, 0x4BCA59ED99CDF8FC,  # k = -105
    0x594BBF71806287F3, 0x563B7B247B0B2D96,  # k = -104
    0x476FCC5ACD1B9FF6, 0x11C92F50626F57AC,  # k = -103
    0x724C7A2AE1C5CCBD, 0x02DB7EE703E55912,  # k = -102
    0x5B7061BBE7D17097, 0x1BE2CBEC031DE0DC,  # k = -101
    0x4926B496530DF3AC, 0x164F09899C17E716,  # k = -100
    0x750ABA8A1E7CB913, 0x3D4B4275C68CA4F0,  # k = -99
    0x5DA22ED4E530940F, 0x4AA29B916BA3B726,  # k = -98
    0x4AE825771DC07672, 0x6EE87C74561C9285,  # k = -97
    0x77D9D58B62CD8A51, 0x3173FA53BCFA8408,  # k = -96
    0x5FE177A2B5713B74, 0x278FFB7630C869A0,  # k = -95
    0x4CB45FB55DF42F90, 0x1FA662C4F3D387B3,  # k = -94
    0x7ABA32BBC986B280, 0x32A3D13B1FB8D91F,  # k = -93
    0x622E8EFCA1388ECD, 0x0EE9742F4C93E0E6,  # k = -92
    0x4E8BA596E760723D, 0x58BAC3590A0FE71E,  # k = -91
    0x7DAC3C24A5671D2F, 0x412AD228101971C9,  # k = -90
    0x6489C9B6EAB8E426, 0x00EF0E8673478E3B,  # k = -89
    0x506E3AF8BBC71CEB, 0x1A58D86B8F6C71C9,  # k = -88
    0x40582F2D6305B0BC, 0x1513E0560C56C16E,  # k = -87
    0x66F37EAF04D5E793, 0x3B530089AD579BE2,  # k = -86
    0x525C6558D0AB1FA9, 0x15DC006E2446164F,  # k = -85
    0x41E384470D55B2ED, 0x5E4999F1B69E783F,  # k = -84
    0x696C06D81555EB15, 0x7D428FE92430C065,  # k = -83
    0x54566BE0111188DE, 0x31020CBA835A3384,  # k = -82
    0x4378564CDA746D7E, 0x5A680A2ECF7B5C69,  # k = -81
    0x6BF3BD47C3ED7BFD, 0x770CDD17B25EFA42,  # k = -80
    0x565C976C9CBDFCCB, 0x1270B0DFC1E59502,  # k = -79
    0x4516DF8A16FE63D5, 0x5B8D5A4C9B1E10CE,  # k = -78
    0x6E8AFF4357FD6C89, 0x127BC3ADC4FCE7B0,  # k = -77
    0x586F329C466456D4, 0x0EC96957D0CA52F3,  # k = -76
    0x46BF5BB038504576, 0x3F07877973D50F29,  # k = -75
    0x71322C4D26E6D58A, 0x31A5A58F1FBB4B75,  # k = -74
    0x5A8E89D75252446E, 0x5AEAEAD8E62F6F91,  # k = -73
    0x487207DF750E9D25, 0x2F22557A51BF8C74,  # k = -72
    0x73E9A63254E42EA2, 0x1836EF2A1C65AD86,  # k = -71
    0x5CBAEB5B771CF21B, 0x2CF8BF54E3848AD2,  # k = -70
    0x4A2F22AF927D8E7C, 0x23FA32AA4F9D3BDB,  # k = -69
    0x76B1D118EA627D93, 0x5329EAAA18FB92F8,  # k = -68
    0x5EF4A74721E86476, 0x0F54BBBB472FA8C6,  # k = -67
    0x4BF6EC38E7ED1D2B, 0x25DD62FC38F2ED6C,  # k = -66
    0x798B138E3FE1C845, 0x22FBD1938E517BDF,  # k = -65
    0x613C0FA4FFE7D36A, 0x4F2FDADC71DAC97F,  # k = -64
    0x4DC9A61D998642BB, 0x58F3157D27E23ACC,  # k = -63
    0x7C75D695C2706AC5, 0x74B82261D969F7AD,  # k = -62
    0x63917877CEC0556B, 0x10934EB4ADEE5FBE,  # k = -61
    0x4FA793930BCD1122, 0x4075D8908B251965,  # k = -60
    0x7F7285B812E1B504, 0x00BC8DB411D4F56E,  # k = -59
    0x65F537C675815D9C, 0x66FD3E29A7DD9125,  # k = -58
    0x5190F96B91344AE3, 0x6BFDCB54864ADA84,  # k = -57
    0x4140C78940F6A24F, 0x6FFE3C439EA2486A,  # k = -56
    0x6867A5A867F103B2, 0x7FFD2D38FDD073DC,  # k = -55
    0x53861E2053273628, 0x6664242D97D9F64A,  # k = -54
    0x42D1B1B375B8F820, 0x51E9B68ADFE191D5,  # k = -53
    0x6AE91C5255F4C034, 0x1CA924116635B621,  # k = -52
    0x558749DB77F70029, 0x63BA83411E915E81,  # k = -51
    0x446C3B15F9926687, 0x6962029A7EDAB201,  # k = -50
    0x6D79F82328EA3DA6, 0x0F03375D97C45001,  # k = -49
    0x5794C6828721CAEB, 0x259C2C4ADFD04001,  # k = -48
    0x46109ECED2816F22, 0x5149BD08B30D0001,  # k = -47
    0x701A97B150CF1837, 0x3542C80DEB480001,  # k = -46
    0x59AEDFC10D7279C5, 0x7768A00B22A00001,  # k = -45
    0x47BF19673DF52E37, 0x79208008E8800001,  # k = -44
    0x72CB5BD86321E38C, 0x5B67334174000001,  # k = -43
    0x5BD5E313828182D6, 0x7C528F6790000001,  # k = -42
    0x4977E8DC68679BDF, 0x16A872B940000001,  # k = -41
    0x758CA7C70D7292FE, 0x5773EAC200000001,  # k = -40
    0x5E0A1FD271287598, 0x45F6556800000001,  # k = -39
    0x4B3B4CA85A86C47A, 0x04C5112000000001,  # k = -38
    0x785EE10D5DA46D90, 0x07A1B50000000001,  # k = -37
    0x604BE73DE4838AD9, 0x52E7C40000000001,  # k = -36
    0x4D0985CB1D3608AE, 0x0F1FD00000000001,  # k = -35
    0x7B426FAB61F00DE3, 0x31CC800000000001,  # k = -34
    0x629B8C891B267182, 0x5B0A000000000001,  # k = -33
    0x4EE2D6D415B85ACE, 0x7C08000000000001,  # k = -32
    0x7E37BE2022C0914B, 0x1340000000000001,  # k = -31
    0x64F964E68233A76F, 0x2900000000000001,  # k = -30
    0x50C783EB9B5C85F2, 0x5400000000000001,  # k = -29
    0x409F9CBC7C4A04C2, 0x1000000000000001,  # k = -28
    0x6765C793FA10079D, 0x0000000000000001,  # k = -27
    0x52B7D2DCC80CD2E4, 0x0000000000000001,  # k = -26
    0x422CA8B0A00A4250, 0x0000000000000001,  # k = -25
    0x69E10DE76676D080, 0x0000000000000001,  # k = -24
    0x54B40B1F852BDA00, 0x0000000000000001,  # k = -23
    0x43C33C1937564800, 0x0000000000000001,  # k = -22
    0x6C6B935B8BBD4000, 0x0000000000000001,  # k = -21
    0x56BC75E2D6310000, 0x0000000000000001,  # k = -20
    0x4563918244F40000, 0x0000000000000001,  # k = -19
    0x6F05B59D3B200000, 0x0000000000000001,  # k = -18
    0x58D15E1762800000, 0x0000000000000001,  # k = -17
    0x470DE4DF82000000, 0x0000000000000001,  # k = -16
    0x71AFD498D0000000, 0x0000000000000001,  # k = -15
    0x5AF3107A40000000, 0x0000000000000001,  # k = -14
    0x48C2739500000000, 0x0000000000000001,  # k = -13
    0x746A528800000000, 0x0000000000000001,  # k = -12
    0x5D21DBA000000000, 0x0000000000000001,  # k = -11
    0x4A817C8000000000, 0x0000000000000001,  # k = -10
    0x7735940000000000, 0x0000000000000001,  # k = -9
    0x5F5E100000000000, 0x0000000000000001,  # k = -8
    0x4C4B400000000000, 0x0000000000000001,  # k = -7
    0x7A12000000000000, 0x0000000000000001,  # k = -6
    0x61A8000000000000, 0x0000000000000001,  # k = -5
    0x4E20000000000000, 0x0000000000000001,  # k = -4
    0x7D00000000000000, 0x0000000000000001,  # k = -3
    0x6400000000000000, 0x0000000000000001,  # k = -2
    0x5000000000000000, 0x0000000000000001,  # k = -1
    0x4000000000000000, 0x0000000000000001,  # k = 0
    0x6666666666666666, 0x3333333333333334,  # k = 1
    0x51EB851EB851EB85, 0x0F5C28F5C28F5C29,  # k = 2
    0x4189374BC6A7EF9D, 0x5916872B020C49BB,  # k = 3
    0x68DB8BAC710CB295, 0x74F0D844D013A92B,  # k = 4
    0x53E2D6238DA3C211, 0x43F3E0370CDC8755,  # k = 5
    0x431BDE82D7B634DA, 0x698FE69270B06C44,  # k = 6
    0x6B5FCA6AF2BD215E, 0x0F4CA41D811A46D4,  # k = 7
    0x55E63B88C230E77E, 0x3F70834ACDAE9F10,  # k = 8
    0x44B82FA09B5A52CB, 0x4C5A02A23E254C0D,  # k = 9
    0x6DF37F675EF6EADF, 0x2D5CD10396A21347,  # k = 10
    0x57F5FF85E592557F, 0x3DE3DA69454E75D3,  # k = 11
    0x465E6604B7A84465, 0x7E4FE1EDD10B9175,  # k = 12
    0x709709A125DA0709, 0x4A19697C81AC1BEF,  # k = 13
    0x5A126E1A84AE6C07, 0x54E1213067BCE326,  # k = 14
    0x480EBE7B9D58566C, 0x43E74DC052FD8285,  # k = 15
    0x734ACA5F6226F0AD, 0x530BAF9A1E626A6D,  # k = 16
    0x5C3BD5191B525A24, 0x426FBFAE7EB521F1,  # k = 17
    0x49C97747490EAE83, 0x4EBFCC8B9890E7F4,  # k = 18
    0x760F253EDB4AB0D2, 0x4ACC7A78F41B0CBA,  # k = 19
    0x5E72843249088D75, 0x223D2EC729AF3D62,  # k = 20
    0x4B8ED0283A6D3DF7, 0x34FDBF05BAF29781,  # k = 21
    0x78E480405D7B9658, 0x54C931A2C4B758CF,  # k = 22
    0x60B6CD004AC94513, 0x5D6DC14F03C5E0A5,  # k = 23
    0x4D5F0A66A23A9DA9, 0x31249AA59C9E4D51,  # k = 24
    0x7BCB43D769F762A8, 0x4EA0F76F60FD4882,  # k = 25
    0x63090312BB2C4EED, 0x254D92BF80CAA068,  # k = 26
    0x4F3A68DBC8F03F24, 0x1DD7A89933D54D20,  # k = 27
    0x7EC3DAF941806506, 0x62F2A75B86221500,  # k = 28
    0x65697BFA9ACD1D9F, 0x025BB91604E810CD,  # k = 29
    0x51212FFBAF0A7E18, 0x684960DE6A5340A4,  # k = 30
    0x40E7599625A1FE7A, 0x203AB3E521DC33B6,  # k = 31
    0x67D88F56A29CCA5D, 0x19F7863B696052BD,  # k = 32
    0x5313A5DEE87D6EB0, 0x7B2C6B62BAB37564,  # k = 33
    0x42761E4BED31255A, 0x2F56BC4EFBC2C450,  # k = 34
    0x6A5696DFE1E83BC3, 0x655793B192D13A1A,  # k = 35
    0x5512124CB4B9C969, 0x377942F475742E7B,  # k = 36
    0x440E750A2A2E3ABA, 0x5F9435905DF68B96,  # k = 37
    0x6CE3EE76A9E3912A, 0x65B9EF4D63241289,  # k = 38
    0x571CBEC554B60DBB, 0x6AFB25D782834207,  # k = 39
    0x45B0989DDD5E7163, 0x08C8EB12CECF6806,  # k = 40
    0x6F80F42FC8971BD1, 0x5ADB11B7B14BD9A3,  # k = 41
    0x5933F68CA078E30E, 0x157C0E2C8DD647B5,  # k = 42
    0x475CC53D4D2D8271, 0x5DFCD823A4AB6C91,  # k = 43
    0x722E086215159D82, 0x632E269F6DDF141B,  # k = 44
    0x5B5806B4DDAAE468, 0x4F581EE5F17F4349,  # k = 45
    0x49133890B1558386, 0x72ACE584C1329C3B,  # k = 46
    0x74EB8DB44EEF38D7, 0x6AAE3C079B842D2A,  # k = 47
    0x5D893E29D8BF60AC, 0x5558300616035755,  # k = 48
    0x4AD431BB13CC4D56, 0x7779C004DE6912AB,  # k = 49
    0x77B9E92B52E07BBE, 0x258F99A163DB5111,  # k = 50
    0x5FC7EDBC424D2FCB, 0x37A614811CAF740D,  # k = 51
    0x4C9FF163683DBFD5, 0x7951AA00E3BF900B,  # k = 52
    0x7A998238A6C932EF, 0x754F7667D2CC19AB,  # k = 53
    0x6214682D523A8F26, 0x2AA5F8530F09AE22,  # k = 54
    0x4E76B9BDDB620C1E, 0x55519375A5A1581B,  # k = 55
    0x7D8AC2C95F034697, 0x3BB5B8BC3C3559C5,  # k = 56
    0x646F023AB2690545, 0x7C9160969691149E,  # k = 57
    0x5058CE955B87376B, 0x16DAB3ABABA743B2,  # k = 58
    0x40470BAAAF9F5F88, 0x78AEF622EFB902F5,  # k = 59
    0x66D812AAB29898DB, 0x0DE4BD04B2C19E54,  # k = 60
    0x524675555BAD4715, 0x57EA30D08F014B76,  # k = 61
    0x41D1F7777C8A9F44, 0x4654F3DA0C01092C,  # k = 62
    0x694FF258C7443207, 0x23BB1FC346680EAC,  # k = 63
    0x543FF513D29CF4D2, 0x4FC8E635D1ECD88A,  # k = 64
    0x43665DA9754A5D75, 0x263A51C4A7F0AD3B,  # k = 65
    0x6BD6FC425543C8BB, 0x56C3B607731AAEC4,  # k = 66
    0x5645969B77696D62, 0x789C919F8F488BD0,  # k = 67
    0x4504787C5F878AB5, 0x46E3A7B2D906D640,  # k = 68
    0x6E6D8D93CC0C1122, 0x3E390C515B3E239A,  # k = 69
    0x5857A4763CD6741B, 0x4B60D6A77C31B615,  # k = 70
    0x46AC8391CA4529AF, 0x55E7121F968E2B44,  # k = 71
    0x711405B6106EA919, 0x0971B698F0E3786D,  # k = 72
    0x5A766AF80D255414, 0x078E2BAD8D82C6BD,  # k = 73
    0x485EBBF9A41DDCDC, 0x6C71BC8AD79BD231,  # k = 74
    0x73CAC65C39C96161, 0x2D82C7448C2C8382,  # k = 75
    0x5CA23849C7D44DE7, 0x3E023903A356CF9B,  # k = 76
    0x4A1B603B06437185, 0x7E682D9C82ABD949,  # k = 77
    0x76923391A39F1C09, 0x4A4048FA6AAC8EDB,  # k = 78
    0x5EDB5C7482E5B007, 0x55003A61EEF07249,  # k = 79
    0x4BE2B05D35848CD2, 0x773361E7F259F507,  # k = 80
    0x796AB3C855A0E151, 0x3EB89CA6508FEE71,  # k = 81
    0x6122296D114D810D, 0x7EFA16EB73A6585B,  # k = 82
    0x4DB4EDF0DAA4673E, 0x3261ABEF8FB846AF,  # k = 83
    0x7C54AFE7C43A3ECA, 0x1D691318E5F3A44B,  # k = 84
    0x6376F31FD02E98A1, 0x64540F471E5C836F,  # k = 85
    0x4F925C1973587A1B, 0x0376729F4B7D35F3,  # k = 86
    0x7F50935BEBC0C35E, 0x38BD84321261EFEB,  # k = 87
    0x65DA0F7CBC9A35E5, 0x13CAD0280EB4BFEF,  # k = 88
    0x517B3F96FD482B1D, 0x5CA240200BC3CCBF,  # k = 89
    0x412F66126439BC17, 0x63B50019A3030A33,  # k = 90
    0x684BD683D38F9359, 0x1F88002904D1A9EA,  # k = 91
    0x536FDECFDC72DC47, 0x32D3335403DAEE55,  # k = 92
    0x42BFE57316C249D2, 0x5BDC291003158B77,  # k = 93
    0x6ACCA251BE03A951, 0x12F9DB4CD1BC1258,  # k = 94
    0x557081DAFE695440, 0x7594AF70A7C9A847,  # k = 95
    0x445A017BFEBAA9CD, 0x4476F2C0863AED06,  # k = 96
    0x6D5CCF2CCAC442E2, 0x3A57EACDA3917B3C,  # k = 97
    0x577D728A3BD03581, 0x7B7988A482DAC8FD,  # k = 98
    0x45FDF53B630CF79B, 0x15FAD3B6CF156D97,  # k = 99
    0x6FFCBB923814BF5E, 0x565E1F8AE4EF15BE,  # k = 100
    0x5996FC74F9AA32B2, 0x11E4E608B725AAFF,  # k = 101
    0x47ABFD2A6154F55B, 0x27EA51A0928488CC,  # k = 102
    0x72ACC843CEEE555E, 0x7310829A84074146,  # k = 103
    0x5BBD6D030BF1DDE5, 0x42739BAED005CDD2,  # k = 104
    0x49645735A327E4B7, 0x4EC2E2F24004A4A8,  # k = 105
    0x756D5855D1D96DF2, 0x4AD16B1D333AA10C,  # k = 106
    0x5DF11377DB1457F5, 0x2241227DC2954DA3,  # k = 107
    0x4B2742C648DD132A, 0x4E9A81FE35443E1C,  # k = 108
    0x783ED13D4161B844, 0x175D9CC9EED39694,  # k = 109
    0x603240FDCDE7C69C, 0x7917B0A18BDC7876,  # k = 110
    0x4CF500CB0B1FD217, 0x1412F3B46FE39392,  # k = 111
    0x7B219ADE7832E9BE, 0x535185ED7FD285B6,  # k = 112
    0x628148B1F9C25498, 0x42A79E57997537C5,  # k = 113
    0x4ECDD3C1949B76E0, 0x3552E512E12A9304,  # k = 114
    0x7E161F9C20F8BE33, 0x6EEB081E3510EB39,  # k = 115
    0x64DE7FB01A609829, 0x3F226CE4F740BC2E,  # k = 116
    0x50B1FFC0151A1354, 0x3281F0B72C33C9BE,  # k = 117
    0x408E66334414DC43, 0x42018D5F568FD498,  # k = 118
    0x674A3D1ED354939F, 0x1CCF48988A7FBA8D,  # k = 119
    0x52A1CA7F0F76DC7F, 0x30A5D3AD3B99620B,  # k = 120
    0x421B0865A5F8B065, 0x73B7DC8A96144E6F,  # k = 121
    0x69C4DA3C3CC11A3C, 0x52BFC7442353B0B1,  # k = 122
    0x549D7B6363CDAE96, 0x756639034F7626F4,  # k = 123
    0x43B12F82B63E2545, 0x4451C735D92B525D,  # k = 124
    0x6C4EB26ABD303BA2, 0x3A1C71EFC1DEEA2E,  # k = 125
    0x56A55B889759C94E, 0x61B05B2634B254F2,  # k = 126
    0x45511606DF7B0772, 0x1AF37C1E908EAA5B,  # k = 127
    0x6EE8233E325E7250, 0x2B1F2CFDB41776F8,  # k = 128
    0x58B9B5CB5B7EC1D9, 0x6F4C23FE29AC5F2D,  # k = 129
    0x46FAF7D5E2CBCE47, 0x72A34FFE87BD18F1,  # k = 130
    0x71918C896ADFB073, 0x04387FFDA5FB5B1B,  # k = 131
    0x5ADAD6D4557FC05C, 0x0360666484C915AF,  # k = 132
    0x48AF1243779966B0, 0x02B3851D3707448C,  # k = 133
    0x744B506BF28F0AB3, 0x1DEC082EBE720746,  # k = 134
    0x5D090D2328726EF5, 0x64BCD358985B3905,  # k = 135
    0x4A6DA41C205B8BF7, 0x6A30A913AD15C738,  # k = 136
    0x7715D36033C5ACBF, 0x5D1AA81F7B560B8C,  # k = 137
    0x5F44A919C3048A32, 0x7DAEECE5FC44D609,  # k = 138
    0x4C36EDAE359D3B5B, 0x7E258A51969D7808,  # k = 139
    0x79F17C49EF61F893, 0x16A276E8F0FBF33F,  # k = 140
    0x618DFD07F2B4C6DC, 0x121B9253F3FCC299,  # k = 141
    0x4E0B30D328909F16, 0x41AFA84329970214,  # k = 142
    0x7CDEB4850DB431BD, 0x4F7F739EA8F19CED,  # k = 143
    0x63E55D373E29C164, 0x3F99294BBA5AE3F1,  # k = 144
    0x4FEAB0F8FE87CDE9, 0x7FADBAA2FB7BE98D,  # k = 145
    0x7FDDE7F4CA72E30F, 0x7F7C5DD1925FDC15,  # k = 146
    0x664B1FF7085BE8D9, 0x4C637E4141E649AB,  # k = 147
    0x51D5B32C06AFED7A, 0x704F983434B83AEF,  # k = 148
    0x4177C2899EF32462, 0x26A6135CF6F9C8BF,  # k = 149
    0x68BF9DA8FE51D3D0, 0x3DD685618B294132,  # k = 150
    0x53CC7E20CB74A973, 0x4B12044E08EDCDC2,  # k = 151
    0x4309FE80A2C3BAC2, 0x6F419D0B3A57D7CE,  # k = 152
    0x6B4330CDD1392AD1, 0x320294DEC3BFBFB0,  # k = 153
    0x55CF5A3E40FA88A7, 0x419BAA4BCFCC995A,  # k = 154
    0x44A5E1CB672ED3B9, 0x1AE2EEA30CA3ADE1,  # k = 155
    0x6DD636123EB152C1, 0x77D17DD1ADD2AFCF,  # k = 156
    0x57DE91A832277567, 0x797464A7BE42263F,  # k = 157
    0x464BA7B9C1B92AB9, 0x4790508631CE84FF,  # k = 158
    0x70790C5C6928445C, 0x0C1A1A704FB0D4CC,  # k = 159
    0x59FA7049EDB9D049, 0x567B4859D95A43D6,  # k = 160
    0x47FB8D07F161736E, 0x11FC39E17AAE9CAB,  # k = 161
    0x732C14D98235857D, 0x032D2968C44A9445,  # k = 162
    0x5C2343E134F79DFD, 0x4F575453D03BA9D1,  # k = 163
    0x49B5CFE75D92E4CA, 0x72AC4376402FBB0E,  # k = 164
    0x75EFB30BC8EB07AB, 0x0446D256CD192B49,  # k = 165
    0x5E595C096D88D2EF, 0x1D0575123DADBC3A,  # k = 166
    0x4B7AB0078AD3DBF2, 0x4A6AC40E97BE302F,  # k = 167
    0x78C44CD8DE1FC650, 0x771139B0F2C9E6B1,  # k = 168
    0x609D0A4718196B73, 0x78DA948D8F07EBC1,  # k = 169
    0x4D4A6E9F467ABC5C, 0x60AEDD3E0C065634,  # k = 170
    0x7BAA4A9870C46094, 0x344AFB9679A3BD20,  # k = 171
    0x62EEA2138D69E6DD, 0x103BFC78614FCA80,  # k = 172
    0x4F254E760ABB1F17, 0x26966393810CA200,  # k = 173
    0x7EA21723445E9825, 0x2423D2859B476999,  # k = 174
    0x654E78E9037EE01D, 0x69B642047C392148,  # k = 175
    0x510B93ED9C658017, 0x6E2B680396941AA0,  # k = 176
    0x40D60FF149EACCDF, 0x71BC53361210154D,  # k = 177
    0x67BCE64EDCAAE166, 0x1C6085235019BBAE,  # k = 178
    0x52FD850BE3BBE784, 0x7D1A041C40149625,  # k = 179
    0x42646A6FE9631F9D, 0x4A7B367D0010781D,  # k = 180
    0x6A3A43E642383295, 0x5D91F0C8001A59C8,  # k = 181
    0x54FB698501C68EDE, 0x17A7F3D3334847D4,  # k = 182
    0x43FC546A67D20BE4, 0x79532975C2A03976,  # k = 183
    0x6CC6ED770C83463B, 0x0EEB75893766C256,  # k = 184
    0x57058AC5A39C382F, 0x25892AD42C523512,  # k = 185
    0x459E089E1C7CF9BF, 0x37A0EF102374F742,  # k = 186
    0x6F6340FCFA618F98, 0x59017E8038BB2536,  # k = 187
    0x591C33FD951AD946, 0x7A67986693C8EA91,  # k = 188
    0x4749C33144157A9F, 0x151FAD1EDCA0BBA8,  # k = 189
    0x720F9EB539BBF765, 0x0832AE97C76792A5,  # k = 190
    0x5B3FB22A94965F84, 0x068EF21305EC7551,  # k = 191
    0x48FFC1BBAA11E603, 0x1ED8C1A8D189F774,  # k = 192
    0x74CC692C434FD66B, 0x4AF4690E1C0FF253,  # k = 193
    0x5D705423690CAB89, 0x225D20D816732843,  # k = 194
    0x4AC0434F873D5607, 0x35174D79AB8F5369,  # k = 195
    0x779A054C0B955672, 0x21BEE25C45B21F0E,  # k = 196
    0x5FAE6AA33C77785B, 0x3498B5169E2818D8,  # k = 197
    0x4C8B888296C5F9E2, 0x5D46F7454B534713,  # k = 198
    0x7A78DA6A8AD65C9D, 0x7BA4BED545520B52,  # k = 199
    0x61FA48553BDEB07E, 0x2FB6FF110441A2A8,  # k = 200
    0x4E61D37763188D31, 0x72F8CC0D9D014EED,  # k = 201
    0x7D6952589E8DAEB6, 0x1E5AE015C80217E1,  # k = 202
    0x645441E07ED7BEF8, 0x1848B344A001ACB4,  # k = 203
    0x504367E6CBDFCBF9, 0x603A2903B3348A2A,  # k = 204
    0x4035ECB8A3196FFB, 0x002E873628F6D4EE,  # k = 205
    0x66BCADF43828B32B, 0x19E40B89DB2487E3,  # k = 206
    0x52308B29C686F5BC, 0x14B66FA17C1D3983,  # k = 207
    0x41C06F549ED25E30, 0x1091F2E7967DC79C,  # k = 208
    0x6933E554315096B3, 0x341CB7D8F0C93F5F,  # k = 209
    0x542984435AA6DEF5, 0x767D5FE0C0A0FF80,  # k = 210
    0x435469CF7BB8B25E, 0x2B977FE70080CC66,  # k = 211
    0x6BBA42E592C11D63, 0x5F58CCA4CD9AE0A3,  # k = 212
    0x562E9BEADBCDB11C, 0x4C470A1D7148B3B6,  # k = 213
    0x44F216557CA48DB0, 0x3D05A1B1276D5C92,  # k = 214
    0x6E5023BBFAA0E2B3, 0x7B3C35E83F1560E9,  # k = 215
    0x58401C96621A4EF6, 0x2F635E5365AAB3ED,  # k = 216
    0x4699B0784E7B725E, 0x591C4B75EAEEF658,  # k = 217
    0x70F5E726E3F8B6FD, 0x74FA125644B18A26,  # k = 218
    0x5A5E5285832D5F31, 0x43FB41DE9D5AD4EB,  # k = 219
    0x484B75379C244C27, 0x4FFC34B2177BDD89,  # k = 220
    0x73ABEEBF603A1372, 0x4CC6BAB68BF96274,  # k = 221
    0x5C898BCC4CFB42C2, 0x0A38955ED6611B90,  # k = 222
    0x4A07A309D72F689B, 0x21C6DDE5784DAFA7,  # k = 223
    0x76729E762518A75E, 0x693E2FD58D49190B,  # k = 224
    0x5EC2185E8413B918, 0x5431BFDE0AA0E0D5,  # k = 225
    0x4BCE79E536762DAD, 0x29C1664B3BB3E711,  # k = 226
    0x794A5CA1F0BD15E2, 0x0F9BD6DEC5ECA4E8,  # k = 227
    0x61084A1B26FDAB1B, 0x2616457F04BD50BA,  # k = 228
    0x4DA03B48EBFE227C, 0x1E783798D09773C8,  # k = 229
    0x7C33920E46636A60, 0x30C058F480F252D9,  # k = 230
    0x635C74D8384F884D, 0x0D66AD9067284247,  # k = 231
    0x4F7D2A469372D370, 0x711EF14052869B6C,  # k = 232
    0x7F2EAA0A85848581, 0x34FE4ECD50D75F14,  # k = 233
    0x65BEEE6ED136D134, 0x2A650BD773DF7F43,  # k = 234
    0x51658B8BDA9240F6, 0x551DA312C319329C,  # k = 235
    0x411E093CAEDB672B, 0x5DB14F4235ADC217,  # k = 236
    0x68300EC77E2BD845, 0x7C4EE536BC49368A,  # k = 237
    0x5359A56C64EFE037, 0x7D0BEA92303A9208,  # k = 238
    0x42AE1DF050BFE693, 0x173CBBA8269541A0,  # k = 239
    0x6AB02FE6E79970EB, 0x3EC792A6A422029A,  # k = 240
    0x5559BFEBEC7AC0BC, 0x3239421EE9B4CEE1,  # k = 241
    0x4447CCBCBD2F0096, 0x5B6101B25490A581,  # k = 242
    0x6D3FADFAC84B3424, 0x2BCE691D541AA268,  # k = 243
    0x576624C8A03C29B6, 0x563EBA7DDCE21B87,  # k = 244
    0x45EB50A08030215E, 0x78322ECB171B4939,  # k = 245
    0x6FDEE76733803564, 0x59E9E47824F87527,  # k = 246
    0x597F1F85C2CCF783, 0x6187E9F9B72D2A86,  # k = 247
    0x4798E6049BD72C69, 0x346CBB2E2C242205,  # k = 248
    0x728E3CD42C8B7A42, 0x20ADF849E039D007,  # k = 249
    0x5BA4FD768A092E9B, 0x33BE603B19C7D99F,  # k = 250
    0x4950CAC53B3A8BAF, 0x42FEB3627B0647B3,  # k = 251
    0x754E113B91F745E5, 0x5197856A5E7072B8,  # k = 252
    0x5DD80DC941929E51, 0x27AC6ABB7EC05BC6,  # k = 253
    0x4B133E3A9ADBB1DA, 0x52F05562CBCD1638,  # k = 254
    0x781EC9F75E2C4FC4, 0x1E4D556ADFAE89F3,  # k = 255
    0x6018A192B1BD0C9C, 0x7EA444557FBED4C3,  # k = 256
    0x4CE0814227CA707D, 0x4BB69D1132FF109C,  # k = 257
    0x7B00CED03FAA4D95, 0x5F8A94E851981A93,  # k = 258
    0x62670BD9CC883E11, 0x32D543ED0E134875,  # k = 259
    0x4EB8D647D6D364DA, 0x5BDDCFF0D80F6D2B,  # k = 260
    0x7DF48A0C8AEBD491, 0x12FC7FE7C018AEAB,  # k = 261
    0x64C3A1A3A25643A7, 0x28C9FFEC99AD5889,  # k = 262
    0x509C814FB511CFB9, 0x0707FFF07AF113A1,  # k = 263
    0x407D343FC40E3FC7, 0x1F39998D2F2742E7,  # k = 264
    0x672EB9FFA016CC71, 0x7EC28F484B7204A4,  # k = 265
    0x528BC7FFB345705B, 0x189BA5D36F8E6A1D,  # k = 266
    0x42096CCC8F6AC048, 0x7A161E42BFA521B1,  # k = 267
    0x69A8AE1418AACD41, 0x435696D132A1CF81,  # k = 268
    0x5486F1A9AD557101, 0x1C454574288172CE,  # k = 269
    0x439F27BAF1112734, 0x169DD129BA0128A5,  # k = 270
    0x6C31D92B1B4EA520, 0x242FB50F9001DAA1,  # k = 271
    0x568E4755AF721DB3, 0x368C90D940017BB4,  # k = 272
    0x453E9F77BF8E7E29, 0x120A0D7A999AC95D,  # k = 273
    0x6ECA98BF98E3FD0E, 0x50101590F5C47561,  # k = 274
    0x58A213CC7A4FFDA5, 0x26734473F7D05DE8,  # k = 275
    0x46E80FD6C83FFE1D, 0x6B8F69F65FD9E4B9,  # k = 276
    0x71734C8AD9FFFCFC, 0x45B24323CC8FD45C,  # k = 277
    0x5AC2A3A247FFFD96, 0x6AF502830A0CA9E3,  # k = 278
    0x489BB61B6CCCCADF, 0x08C402026E7087E9,  # k = 279
    0x742C569247AE1164, 0x746CD003E3E73FDB,  # k = 280
    0x5CF04541D2F1A783, 0x76BD73364FEC3315,  # k = 281
    0x4A59D101758E1F9C, 0x5EFDF5C50CBCF5AB,  # k = 282
    0x76F61B3588E365C7, 0x4B2FEFA1ADFB22AB,  # k = 283
    0x5F2B48F7A0B5EB06, 0x08F3261AF195B555,  # k = 284
    0x4C22A0C61A2B226B, 0x20C284E25ADE2AAB,  # k = 285
    0x79D1013CF6AB6A45, 0x1AD0D49D5E304444,  # k = 286
    0x617400FD9222BB6A, 0x48A7107DE4F369D0,  # k = 287
    0x4DF6673141B562BB, 0x53B8D9FE50C2BB0D,  # k = 288
    0x7CBD71E869223792, 0x52C15CCA1AD12B48,  # k = 289
    0x63CAC186BA81C60E, 0x75677D6E7BDA8906,  # k = 290
    0x4FD5679EFB9B04D8, 0x5DEC645863153A6C,  # k = 291
    0x7FBBD8FE5F5E6E27, 0x497A3A2704EEC3DF,  # k = 292
]
# fmt: on
# END GENERATED FLOAT TABLES


# ----------------------------------------------------------------------------
# Decimal -> Float64 conversion (correctly rounded)
#
# The stdlib atof is not correctly rounded in Mojo 1.0 (for example
# atof("9.359092726090462e16") is off by one ULP) and rejects mantissas
# longer than 19 digits, so the parser does its own conversion:
#   * Clinger's fast path when the mantissa and the power of ten are both
#     exact in Float64 (one correctly rounded IEEE multiply/divide).
#   * Eisel-Lemire for up to 19 significant digits and any exponent
#     (fast_float; also used by Rust, Go and GCC): one or two 64x128-bit
#     multiplications against the _POW5_128 table.
#   * Otherwise (rare: undecidable products, or >19 digits whose
#     truncation straddles a rounding boundary) a bounded-cost slow path:
#     a candidate within an ULP, and
#     exact big-integer comparisons against the neighbouring halfway
#     points pick the correctly rounded result. Mantissas are capped at
#     800 significant digits (plus a sticky bit), enough to decide every
#     halfway case, so adversarial input costs a few microseconds per
#     number instead of hundreds.
# ----------------------------------------------------------------------------

comptime _MAX_DECIMAL_DIGITS = 800
# Max bits shifted at once; keeps 10 * 2^k + 9 within Int64.
comptime _MAX_SHIFT = 59
comptime _MANT_BITS = 52
comptime _EXP_BITS = 11
comptime _EXP_BIAS = -1023


def _pow2_step(dp: Int) -> Int:
    """Binary shift that moves a decimal with |dp| = dp toward [0.5, 1)
    without overshooting (Go strconv's powtab)."""
    if dp == 0:
        return 1
    elif dp == 1:
        return 3
    elif dp == 2:
        return 6
    elif dp == 3:
        return 9
    elif dp == 4:
        return 13
    elif dp == 5:
        return 16
    elif dp == 6:
        return 19
    elif dp == 7:
        return 23
    elif dp == 8:
        return 26
    return 27


struct _Decimal(Movable):
    """Exact decimal 0.d[0]d[1]...d[n-1] x 10^dp, digit values 0-9.

    Holds at most `cap` digits; `trunc` records that non-zero digits were
    dropped beyond that.
    """

    var d: List[UInt8]
    var dp: Int
    var trunc: Bool
    var cap: Int

    def __init__(out self, cap: Int):
        self.d = List[UInt8](capacity=min(cap, 64))
        self.dp = 0
        self.trunc = False
        self.cap = cap

    def push_digit(mut self, digit: UInt8):
        if len(self.d) < self.cap:
            self.d.append(digit)
        elif digit != 0:
            self.trunc = True

    def trim(mut self):
        while self.d and self.d[len(self.d) - 1] == 0:
            _ = self.d.pop()
        if not self.d:
            self.dp = 0

    def _left_shift(mut self, k: Int):
        """Multiply by 2^k."""
        var rev = List[UInt8](capacity=len(self.d) + 20)
        var n = 0
        for r in range(len(self.d) - 1, -1, -1):
            n += Int(self.d[r]) << k
            var q = n // 10
            rev.append(UInt8(n - 10 * q))
            n = q
        while n > 0:
            var q = n // 10
            rev.append(UInt8(n - 10 * q))
            n = q
        self.dp += len(rev) - len(self.d)
        var drop = max(len(rev) - self.cap, 0)
        for i in range(drop):
            if rev[i] != 0:
                self.trunc = True
        var out = List[UInt8](capacity=len(rev) - drop)
        for i in range(len(rev) - 1, drop - 1, -1):
            out.append(rev[i])
        self.d = out^
        self.trim()

    def _right_shift(mut self, k: Int):
        """Divide by 2^k."""
        var nd = len(self.d)
        var r = 0
        var n = 0
        while (n >> k) == 0:
            if r >= nd:
                if n == 0:
                    self.d.clear()
                    self.dp = 0
                    return
                while (n >> k) == 0:
                    n *= 10
                    r += 1
                break
            n = n * 10 + Int(self.d[r])
            r += 1
        self.dp -= r - 1
        var mask = (1 << k) - 1
        var out = List[UInt8](capacity=nd + 20)
        while r < nd:
            out.append(UInt8(n >> k))
            n = (n & mask) * 10 + Int(self.d[r])
            r += 1
        while n > 0:
            var dig = n >> k
            n &= mask
            if len(out) < self.cap:
                out.append(UInt8(dig))
            elif dig > 0:
                self.trunc = True
            n *= 10
        self.d = out^
        self.trim()

    def shift(mut self, k: Int):
        """Multiply (k > 0) or divide (k < 0) by 2^|k|."""
        if not self.d:
            return
        var rem = k
        while rem > _MAX_SHIFT:
            self._left_shift(_MAX_SHIFT)
            rem -= _MAX_SHIFT
        while rem < -_MAX_SHIFT:
            self._right_shift(_MAX_SHIFT)
            rem += _MAX_SHIFT
        if rem > 0:
            self._left_shift(rem)
        elif rem < 0:
            self._right_shift(-rem)

    def _should_round_up(self, nd: Int) -> Bool:
        if nd < 0 or nd >= len(self.d):
            return False
        if self.d[nd] == 5 and nd + 1 == len(self.d):
            # Exactly halfway: round to even (unless digits were dropped)
            if self.trunc:
                return True
            return nd > 0 and self.d[nd - 1] % 2 == 1
        return self.d[nd] >= 5

    def rounded_integer(self) -> Int:
        """Integer part, rounded half-to-even. Caller ensures dp <= 18."""
        var n = 0
        var i = 0
        while i < self.dp and i < len(self.d):
            n = n * 10 + Int(self.d[i])
            i += 1
        while i < self.dp:
            n *= 10
            i += 1
        if self._should_round_up(self.dp):
            n += 1
        return n

    def to_float(mut self) -> Float64:
        """Correctly rounded magnitude as Float64 (inf on overflow)."""
        if not self.d or self.dp < -330:
            return 0.0
        if self.dp > 310:
            return Float64.MAX * 2.0  # inf
        # Scale by powers of two until in [0.5, 1)
        var exp = 0
        while self.dp > 0:
            var n = _pow2_step(self.dp)
            self.shift(-n)
            exp += n
        while self.dp < 0 or (self.dp == 0 and self.d[0] < 5):
            var n = _pow2_step(-self.dp)
            self.shift(n)
            exp -= n
        # [0.5, 1) -> [1, 2)
        exp -= 1
        # Below the minimum normal exponent: denormalize
        if exp < _EXP_BIAS + 1:
            var n = _EXP_BIAS + 1 - exp
            self.shift(-n)
            exp += n
        if exp - _EXP_BIAS >= (1 << _EXP_BITS) - 1:
            return Float64.MAX * 2.0
        # Extract 1 + _MANT_BITS bits
        self.shift(1 + _MANT_BITS)
        var mant = self.rounded_integer()
        # Rounding may have carried into a new bit
        if mant == 2 << _MANT_BITS:
            mant >>= 1
            exp += 1
            if exp - _EXP_BIAS >= (1 << _EXP_BITS) - 1:
                return Float64.MAX * 2.0
        if mant & (1 << _MANT_BITS) == 0:
            exp = _EXP_BIAS  # subnormal
        var bits = UInt64(mant & ((1 << _MANT_BITS) - 1)) | (
            UInt64((exp - _EXP_BIAS) & ((1 << _EXP_BITS) - 1)) << _MANT_BITS
        )
        return bitcast[DType.float64](bits)


comptime _EL_MIN_Q = -342  # smallest q in _POW5_128
comptime _EL_MAX_Q = 308
comptime _INF_BITS: Int64 = 0x7FF0000000000000


def _eisel_lemire(w: UInt64, q: Int) -> Int64:
    """Eisel-Lemire: bits of the double nearest to w * 10^q.

    Port of fast_float's compute_float (Lemire, "Number Parsing at a
    Gigabyte per Second", 2021). Multiplies the normalized mantissa by a
    128-bit approximation of 5^q from _POW5_128. Returns -1 when that
    approximation cannot decide the rounding (the caller then uses the
    exact slow path), 0 on underflow, and the bits of +inf on overflow.
    """
    if w == 0 or q < _EL_MIN_Q:
        return 0
    if q > _EL_MAX_Q:
        return _INF_BITS
    var lz = Int(count_leading_zeros(w))
    var ws = w << UInt64(lz)
    ref table = global_constant[_POW5_128]()
    var index = 2 * (q - _EL_MIN_Q)
    var first = UInt128(ws) * UInt128(table[index])
    var hi = UInt64(first >> 64)
    var lo = UInt64(first & 0xFFFFFFFFFFFFFFFF)
    # 55 = 52 mantissa bits + 3: if the bits that decide rounding are all
    # ones, refine with the low half of the 128-bit power.
    comptime PRECISION_MASK = UInt64(0xFFFFFFFFFFFFFFFF) >> 55
    if (hi & PRECISION_MASK) == PRECISION_MASK:
        var second_hi = UInt64((UInt128(ws) * UInt128(table[index + 1])) >> 64)
        lo += second_hi
        if second_hi > lo:
            hi += 1
    # Conservative guard from the original algorithm: outside the range
    # where the product is exact, an all-ones low word is undecidable.
    if lo == 0xFFFFFFFFFFFFFFFF and (q < -27 or q > 55):
        return -1
    var upperbit = Int(hi >> 63)
    var shift = upperbit + 64 - _MANT_BITS - 3
    var mantissa = hi >> UInt64(shift)
    # power(q) = floor(q * log2(10)) + 63
    var power2 = (((152170 + 65536) * q) >> 16) + 63 + upperbit - lz - _EXP_BIAS
    if power2 <= 0:  # subnormal
        if -power2 + 1 >= 64:
            return 0
        mantissa >>= UInt64(-power2 + 1)
        mantissa += mantissa & 1  # round half up; ties are impossible here
        mantissa >>= 1
        # A carry into bit 52 makes it the smallest normal number
        power2 = 0 if mantissa < (UInt64(1) << _MANT_BITS) else 1
        return Int64(mantissa | (UInt64(power2) << _MANT_BITS))
    # Exactly halfway (possible only for small |q|): round to even
    if (
        lo <= 1
        and q >= -4
        and q <= 23
        and (mantissa & 3) == 1
        and (mantissa << UInt64(shift)) == hi
    ):
        mantissa &= ~UInt64(1)
    mantissa += mantissa & 1
    mantissa >>= 1
    if mantissa >= (UInt64(2) << _MANT_BITS):
        mantissa = UInt64(1) << _MANT_BITS
        power2 += 1
    mantissa &= ~(UInt64(1) << _MANT_BITS)
    if power2 >= 0x7FF:
        return _INF_BITS
    return Int64(mantissa | (UInt64(power2) << _MANT_BITS))


def _read_exponent(data_ptr: Pointer[UInt8, _], mut i: Int, end: Int) -> Int:
    """Read a validated exponent body ([+-]digits) at i, up to end."""
    var negative = False
    if data_ptr[unsafe_offset=i] == _MINUS:
        negative = True
        i += 1
    elif data_ptr[unsafe_offset=i] == _PLUS:
        i += 1
    var value = 0
    while i < end:
        # Clamp: anything this large already over/underflows
        if value < 100_000_000:
            value = value * 10 + Int(data_ptr[unsafe_offset=i] - _ZERO)
        i += 1
    return -value if negative else value


def _decimal_from_token(
    data_ptr: Pointer[UInt8, _], start: Int, end: Int, cap: Int
) -> _Decimal:
    """Load an unsigned, validated number token into a _Decimal holding
    at most `cap` significant digits."""
    var dec = _Decimal(cap)
    var in_fraction = False
    var i = start
    while i < end:
        var c = data_ptr[unsafe_offset=i]
        i += 1
        if c == _DOT:
            in_fraction = True
        elif c == _LOWER_E or c == _UPPER_E:
            dec.dp += _read_exponent(data_ptr, i, end)
            break
        elif not dec.d and c == _ZERO:
            if in_fraction:
                dec.dp -= 1  # 0.00x: leading fraction zeros shift dp
        else:
            dec.push_digit(c - _ZERO)
            if not in_fraction:
                dec.dp += 1
    dec.trim()
    return dec^


struct _BigUInt(Copyable, Movable):
    """Minimal arbitrary-precision unsigned integer (little-endian 64-bit
    limbs, no leading zero limbs) for the exact float comparison."""

    var limbs: List[UInt64]

    def __init__(out self, value: UInt64):
        self.limbs = List[UInt64](capacity=8)
        if value != 0:
            self.limbs.append(value)

    def __init__(out self, *, copy: Self):
        self.limbs = copy.limbs.copy()

    def mul_small(mut self, factor: UInt64):
        var carry: UInt128 = 0
        for i in range(len(self.limbs)):
            var prod = UInt128(self.limbs[i]) * UInt128(factor) + carry
            self.limbs[i] = UInt64(prod & 0xFFFFFFFFFFFFFFFF)
            carry = prod >> 64
        if carry != 0:
            self.limbs.append(UInt64(carry))

    def add_small(mut self, value: UInt64):
        var carry = UInt128(value)
        var i = 0
        while carry != 0 and i < len(self.limbs):
            var total = UInt128(self.limbs[i]) + carry
            self.limbs[i] = UInt64(total & 0xFFFFFFFFFFFFFFFF)
            carry = total >> 64
            i += 1
        if carry != 0:
            self.limbs.append(UInt64(carry))

    def mul_pow5(mut self, k: Int):
        """Multiply by 5^k."""
        comptime POW5_27: UInt64 = 7450580596923828125  # largest 5^n < 2^64
        var rem = k
        while rem >= 27:
            self.mul_small(POW5_27)
            rem -= 27
        var tail: UInt64 = 1
        for _ in range(rem):
            tail *= 5
        if tail != 1:
            self.mul_small(tail)

    def shl(mut self, bits: Int):
        """Multiply by 2^bits."""
        if not self.limbs or bits == 0:
            return
        var limb_shift = bits // 64
        var bit_shift = bits % 64
        var out = List[UInt64](capacity=len(self.limbs) + limb_shift + 1)
        for _ in range(limb_shift):
            out.append(0)
        if bit_shift == 0:
            for i in range(len(self.limbs)):
                out.append(self.limbs[i])
        else:
            var carry: UInt64 = 0
            for i in range(len(self.limbs)):
                var limb = self.limbs[i]
                out.append((limb << UInt64(bit_shift)) | carry)
                carry = limb >> UInt64(64 - bit_shift)
            if carry != 0:
                out.append(carry)
        self.limbs = out^

    def compare(self, other: Self) -> Int:
        """-1, 0, or 1 as self is less than, equal to, or greater."""
        if len(self.limbs) != len(other.limbs):
            return -1 if len(self.limbs) < len(other.limbs) else 1
        for i in range(len(self.limbs) - 1, -1, -1):
            if self.limbs[i] != other.limbs[i]:
                return -1 if self.limbs[i] < other.limbs[i] else 1
        return 0


struct _ExactDecimal(Movable):
    """V = digits * 10^e10 (+ a sticky epsilon), prepared for comparing V
    against halfway points (2m + 1) * 2^(e2 - 1) between adjacent
    doubles."""

    var scaled: _BigUInt  # digits * 5^e10 if e10 >= 0, else digits
    var pow5: _BigUInt  # 5^-e10 if e10 < 0, else 1
    var e10: Int
    var sticky: Bool

    def __init__(out self, dec: _Decimal):
        var digits = _BigUInt(0)
        var i = 0
        var n = len(dec.d)
        while i < n:
            var chunk: UInt64 = 0
            var scale: UInt64 = 1
            var j = i
            while j < n and j < i + 19:
                chunk = chunk * 10 + UInt64(dec.d[j])
                scale *= 10
                j += 1
            digits.mul_small(scale)
            digits.add_small(chunk)
            i = j
        self.e10 = dec.dp - n
        self.sticky = dec.trunc
        self.pow5 = _BigUInt(1)
        if self.e10 >= 0:
            digits.mul_pow5(self.e10)
        else:
            self.pow5.mul_pow5(-self.e10)
        self.scaled = digits^

    def compare_halfway(self, bits: UInt64) -> Int:
        """Sign of V - H, where H is the midpoint between the positive
        double with these bits and the next double up."""
        var biased = Int(bits >> _MANT_BITS)
        var mant = bits & ((UInt64(1) << _MANT_BITS) - 1)
        var e2: Int
        if biased == 0:
            e2 = 1 - (-_EXP_BIAS) - _MANT_BITS  # subnormal: 2^-1074
        else:
            mant |= UInt64(1) << _MANT_BITS
            e2 = biased + _EXP_BIAS - _MANT_BITS
        # V = scaled * 2^lhs_exp (* 5^-k folded into rhs when e10 < 0)
        # H = (2 * mant + 1) * 2^(e2 - 1)
        var lhs = self.scaled.copy()
        var rhs = self.pow5.copy()
        rhs.mul_small(2 * mant + 1)
        var lhs_exp = self.e10 if self.e10 >= 0 else 0
        var rhs_exp = e2 - 1 + (-self.e10 if self.e10 < 0 else 0)
        if lhs_exp > rhs_exp:
            lhs.shl(lhs_exp - rhs_exp)
        else:
            rhs.shl(rhs_exp - lhs_exp)
        var c = lhs.compare(rhs)
        if c == 0 and self.sticky:
            return 1
        return c


def _slow_parse_float(
    data_ptr: Pointer[UInt8, _],
    start: Int,
    end: Int,
    m: UInt64,
    nd: Int,
    e10: Int,
) -> Float64:
    """Correctly rounded magnitude of an unsigned number token when
    Eisel-Lemire cannot decide (inf on overflow). m is the first nd <= 19
    significant digits and value ~= m * 10^e10."""
    comptime MAX_FINITE_BITS: UInt64 = 0x7FEFFFFFFFFFFFFF
    if m == 0 or e10 + nd < -330:
        return 0.0
    if e10 + nd > 310:
        return Float64.MAX * 2.0  # inf
    # Candidate within about an ULP: Eisel-Lemire on the truncated
    # mantissa, or a 40-digit decimal approximation if that is undecided.
    var bits: UInt64
    var el = _eisel_lemire(m, e10)
    if el >= 0:
        bits = UInt64(el)
    else:
        var approx = _decimal_from_token(data_ptr, start, end, 40)
        bits = bitcast[DType.uint64](approx.to_float())
    if bits > MAX_FINITE_BITS:
        bits = MAX_FINITE_BITS  # inf candidate: start from the max finite

    # Exact value (800 digits + sticky decide every halfway case)
    var exact = _ExactDecimal(
        _decimal_from_token(data_ptr, start, end, _MAX_DECIMAL_DIGITS)
    )
    while True:
        # Above the midpoint with the next double (ties to even)?
        var up = exact.compare_halfway(bits)
        if up > 0 or (up == 0 and (bits & 1) == 1):
            if bits == MAX_FINITE_BITS:
                return Float64.MAX * 2.0  # inf
            bits += 1
            continue
        # Below the midpoint with the previous double?
        if bits > 0:
            var down = exact.compare_halfway(bits - 1)
            if down < 0 or (down == 0 and ((bits - 1) & 1) == 0):
                bits -= 1
                continue
        return bitcast[DType.float64](bits)


def _exact_pow10(e: Int) -> Float64:
    """10^e for 0 <= e <= 22 (the powers of ten exact in Float64)."""
    if e == 0:
        return 1e0
    elif e == 1:
        return 1e1
    elif e == 2:
        return 1e2
    elif e == 3:
        return 1e3
    elif e == 4:
        return 1e4
    elif e == 5:
        return 1e5
    elif e == 6:
        return 1e6
    elif e == 7:
        return 1e7
    elif e == 8:
        return 1e8
    elif e == 9:
        return 1e9
    elif e == 10:
        return 1e10
    elif e == 11:
        return 1e11
    elif e == 12:
        return 1e12
    elif e == 13:
        return 1e13
    elif e == 14:
        return 1e14
    elif e == 15:
        return 1e15
    elif e == 16:
        return 1e16
    elif e == 17:
        return 1e17
    elif e == 18:
        return 1e18
    elif e == 19:
        return 1e19
    elif e == 20:
        return 1e20
    elif e == 21:
        return 1e21
    return 1e22


def _digits_to_float(
    m: UInt64,
    nd: Int,
    e10: Int,
    dropped: Bool,
    data_ptr: Pointer[UInt8, _],
    digits_start: Int,
    end: Int,
) -> Float64:
    """Nearest Float64 to m * 10^e10 (inf on overflow), where m holds the
    first nd <= 19 significant digits of the unsigned token at
    [digits_start, end) and `dropped` says non-zero digits followed."""
    if m == 0:
        return 0.0
    if not dropped and m < (1 << 53) and e10 >= -22 and e10 <= 22:
        # Clinger fast path: m and 10^|e10| are exact doubles, so a
        # single IEEE multiply/divide rounds correctly.
        var p = _exact_pow10(e10 if e10 > 0 else -e10)
        return Float64(m) * p if e10 >= 0 else Float64(m) / p
    # Eisel-Lemire. With dropped digits the value lies in
    # [m, m + 1) * 10^e10; if both ends round to the same double, that
    # double is the answer. Otherwise use the exact slow path.
    var bits = _eisel_lemire(m, e10)
    if dropped and bits >= 0 and _eisel_lemire(m + 1, e10) != bits:
        bits = -1
    if bits >= 0:
        return bitcast[DType.float64](bits)
    return _slow_parse_float(data_ptr, digits_start, end, m, nd, e10)


def _parse_object(
    data_ptr: Pointer[UInt8, _],
    data_len: Int,
    mut pos: Int,
    depth: Int,
    max_depth: Int,
) raises -> JsonValue:
    """Parse a JSON object (pos at '{')."""
    if depth > max_depth:
        raise Error(
            "maximum nesting depth "
            + String(max_depth)
            + " exceeded at position "
            + String(pos)
        )
    pos += 1  # skip '{'

    var obj = json_object()

    _skip_whitespace(data_ptr, data_len, pos)
    if pos < data_len and data_ptr[unsafe_offset=pos] == _RBRACE:
        pos += 1  # empty object
        return obj^
    # Non-empty: reserve a few slots up front (empty objects allocate nothing)
    obj._obj_ptr.unsafe_value()[]._keys.reserve(4)
    obj._obj_ptr.unsafe_value()[]._values.reserve(4)

    while True:
        _skip_whitespace(data_ptr, data_len, pos)
        # Parse key
        if pos >= data_len or data_ptr[unsafe_offset=pos] != _QUOTE:
            raise Error("expected string key at position " + String(pos))
        var key = _parse_string(data_ptr, data_len, pos)

        # Expect colon
        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len or data_ptr[unsafe_offset=pos] != _COLON:
            raise Error("expected ':' at position " + String(pos))
        pos += 1  # skip ':'

        # Duplicate keys keep their first position and take the last value
        var value = _parse_value(data_ptr, data_len, pos, depth, max_depth)
        obj._obj_ptr.unsafe_value()[].set(key^, value^)

        # Expect comma or closing brace
        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len:
            raise Error("unterminated object")
        if data_ptr[unsafe_offset=pos] == _RBRACE:
            pos += 1
            return obj^
        elif data_ptr[unsafe_offset=pos] == _COMMA:
            pos += 1
        else:
            raise Error("expected ',' or '}' at position " + String(pos))


def _parse_array(
    data_ptr: Pointer[UInt8, _],
    data_len: Int,
    mut pos: Int,
    depth: Int,
    max_depth: Int,
) raises -> JsonValue:
    """Parse a JSON array (pos at '[')."""
    if depth > max_depth:
        raise Error(
            "maximum nesting depth "
            + String(max_depth)
            + " exceeded at position "
            + String(pos)
        )
    pos += 1  # skip '['

    var arr = json_array()

    _skip_whitespace(data_ptr, data_len, pos)
    if pos < data_len and data_ptr[unsafe_offset=pos] == _RBRACKET:
        pos += 1  # empty array
        return arr^
    # Non-empty: reserve a few slots up front (empty arrays allocate nothing)
    arr._arr_ptr.unsafe_value()[].reserve(4)

    while True:
        var value = _parse_value(data_ptr, data_len, pos, depth, max_depth)
        arr._arr_ptr.unsafe_value()[].append(value^)

        _skip_whitespace(data_ptr, data_len, pos)
        if pos >= data_len:
            raise Error("unterminated array")
        if data_ptr[unsafe_offset=pos] == _RBRACKET:
            pos += 1
            return arr^
        elif data_ptr[unsafe_offset=pos] == _COMMA:
            pos += 1
        else:
            raise Error("expected ',' or ']' at position " + String(pos))


def _expect_literal[
    word: StaticString
](data_ptr: Pointer[UInt8, _], data_len: Int, mut pos: Int) raises:
    """Consume the literal `word` (true/false/null) at pos."""
    comptime n = word.byte_length()
    if pos + n > data_len:
        raise Error("invalid literal at position " + String(pos))
    comptime for i in range(n):
        if data_ptr[unsafe_offset=pos + i] != UInt8(word.as_bytes()[i]):
            raise Error("invalid literal at position " + String(pos))
    pos += n
