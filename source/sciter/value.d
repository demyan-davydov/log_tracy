//! SciterValue: the D wrapper over SCITER_VALUE (numbers, strings, arrays, maps,
//! functions).
module sciter.value;

import sciter.capi.types;
import sciter.capi.value;
import sciter.api : sciterApi;
import std.utf : toUTF16;

/// 
/// @brief Wraper for SCITER_VALUE
///

/// @brief Checks if two SCITER_VALUE's are refferes to the same object
/// @todo probably is more correct to compare them by value because SCITER_VALUE itself is a reverence type
private bool isSame(const(SCITER_VALUE)* value1, const(SCITER_VALUE)* value2) nothrow @safe @nogc
{
    return value1 is value2;
}

private void ensureSciterValueIsValid(const(SCITER_VALUE)* value)
{
    if (value is null)
        throw new Exception("SCITER_VALUE should not be null");
}

//! @brief It is a reference to a const SCITER_VALUE. It is own value.
struct SciterValueConstView
{
    private const(SCITER_VALUE)* _value;

    @property const(SCITER_VALUE)* raw() const nothrow @nogc
    {
        return _value;
    }

    this() @disable;

    //! @brief a special version of assign for internal use - we do not check if the value is valid.
    //! @note we do not check if the value is not valid.
    this(const(SCITER_VALUE)* value)
    {
        ensureSciterValueIsValid(value);
        _value = value;
    }

    private this(ref const(SCITER_VALUE) value) nothrow @nogc
    {
        _value = &value;
    }

    this(in SciterValueConstView value) nothrow @nogc
    {
        _value = value._value;
    }

    this(in SciterValue value) nothrow @nogc
    {
        _value = value.raw;
    }

    bool opEquals(in const(SciterValueConstView) other) const nothrow @nogc
    {
        // Observed: -1 (HV_OK_TRUE) for equal, 0 (HV_OK) for not equal.

        const auto res = sciterApi().ValueCompare(raw, other.raw);
        return res == VALUE_RESULT.HV_OK_TRUE;
    }

    ///
    /// opAssign() methods
    ///

    //! @brief a special version of assign for internal use - we do not check if the value is valid.
    private void opAssign(ref const(SCITER_VALUE) value) nothrow @nogc
    {
        if (!isSame(raw, &value))
        {
            _value = &value;
        }
    }

    void opAssign(const(SCITER_VALUE)* value)
    {
        ensureSciterValueIsValid(value);
        opAssign(*value);
    }

    void opAssign(in const(SciterValueConstView) other) nothrow @nogc
    {
        if (!isSame(raw, other.raw))
        {
            _value = other.raw;
        }
    }

    void opAssign(in SciterValue other) nothrow @nogc
    {
        if (!isSame(raw, other.raw))
        {
            _value = other.raw;
        }
    }

    ///
    /// tryGet() methods
    ///

    bool tryGet(out int result) const nothrow
    {
        return sciterApi().ValueIntData(raw, &result) == VALUE_RESULT.HV_OK;
    }

    bool tryGet(out long result) const nothrow
    {
        return sciterApi().ValueInt64Data(raw, &result) == VALUE_RESULT.HV_OK;
    }

    bool tryGet(out ulong result) const nothrow
    {
        return sciterApi().ValueInt64Data(raw, cast(long*)&result) == VALUE_RESULT.HV_OK;
    }

    bool tryGet(out double result) const nothrow
    {
        return sciterApi().ValueFloatData(raw, &result) == VALUE_RESULT.HV_OK;
    }

    bool tryGet(out float result) const nothrow
    {
        double d;
        if (sciterApi().ValueFloatData(raw, &d) == VALUE_RESULT.HV_OK)
        {
            result = cast(float) d;
            return true;
        }
        return false;
    }

    bool tryGet(out bool result) const nothrow
    {
        int i;
        if (sciterApi().ValueIntData(raw, &i) == VALUE_RESULT.HV_OK)
        {
            result = i != 0;
            return true;
        }
        return false;
    }

    bool tryGet(out const(wchar)[] result) const nothrow
    {
        const(wchar)* data;
        UINT length;
        if (sciterApi().ValueStringData(raw, &data, &length) == VALUE_RESULT.HV_OK)
        {
            result = data[0 .. length];
            return true;
        }
        return false;
    }

    bool tryGet(out const(ubyte)[] result) const nothrow
    {
        const(ubyte)* data;
        UINT length;
        if (sciterApi().ValueBinaryData(raw, &data, &length) == VALUE_RESULT.HV_OK)
        {
            result = data[0 .. length];
            return true;
        }
        return false;
    }

    bool tryGetColor(out UINT result) const nothrow
    {
        if (isColor())
            return sciterApi().ValueIntData(raw, cast(INT*)&result) == VALUE_RESULT.HV_OK;
        return false;
    }

    // returns radians if isAngle()
    bool tryGetAngle(out double result) const nothrow
    {
        if (isAngle())
            return sciterApi().ValueFloatData(raw, &result) == VALUE_RESULT.HV_OK;
        return false;
    }

    // returns seconds if isDuration()
    bool tryGetDuration(out double result) const nothrow
    {
        if (isDuration())
            return sciterApi().ValueFloatData(raw, &result) == VALUE_RESULT.HV_OK;
        return false;
    }

    ///
    /// isType() methods
    /// 

    bool isUndefined() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_UNDEFINED;
    }

    bool isBool() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_BOOL;
    }

    bool isInt() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_INT;
    }

    bool isFloat() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_FLOAT;
    }

    bool isString() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_STRING;
    }

    bool isSymbol() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_STRING && raw.u == VALUE_UNIT_TYPE_STRING.UT_STRING_SYMBOL;
    }

    bool isErrorString() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_STRING && raw.u == VALUE_UNIT_TYPE_STRING.UT_STRING_ERROR;
    }

    bool isDate() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_DATE;
    }

    bool isBigInt() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_BIG_INT;
    }

    bool isMap() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_MAP;
    }

    bool isArray() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_ARRAY;
    }

    bool isArrayLike() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_ARRAY || (raw.t == VALUE_TYPE.T_OBJECT && raw.u == VALUE_UNIT_TYPE_OBJECT
                .UT_OBJECT_ARRAY);
    }

    bool isFunction() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_FUNCTION;
    }

    bool isBytes() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_BYTES || (raw.t == VALUE_TYPE.T_OBJECT && raw.u == VALUE_UNIT_TYPE_OBJECT
                .UT_OBJECT_BUFFER);
    }

    bool isObject() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_OBJECT;
    }

    //bool is_dom_element() const { return t == T_DOM_OBJECT; }
    // if it is a native functor reference
    bool isNativeFunction() const nothrow @nogc
    {
        return !!sciterApi().ValueIsNativeFunctor(_value);
    }

    bool isAsset() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_ASSET;
    }

    bool isColor() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_COLOR;
    }

    bool isDuration() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_DURATION;
    }

    bool isAngle() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_ANGLE;
    }

    bool isNull() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_NULL && raw.u == 0;
    }

    bool isNothing() const nothrow @nogc
    {
        return raw.t == VALUE_TYPE.T_UNDEFINED && raw.u == VALUE_UNIT_UNDEFINED.UT_NOTHING;
    }

    /// 
    /// to!type() methods
    ///

    T to(T)() const
    {
        T result;
        if (tryGet(result))
        {
            return result;
        }

        throw new Exception("Value is not a " ~ T.stringof);
    }

    const(wchar)[] toString(VALUE_STRING_CVT_TYPE how = VALUE_STRING_CVT_TYPE.CVT_SIMPLE) const
    {
        const(wchar)[] res;
        if (how == VALUE_STRING_CVT_TYPE.CVT_SIMPLE && isString())
        {
            if (!tryGet(res))
            {
                throw new Exception("Value is not a string");
            }
        }
        else
        {
            SciterValue tv = _value;
            sciterApi().ValueToString(&tv._value, cast(UINT) how);

            if (!tv.tryGet(res))
            {
                throw new Exception("Value is not a string");
            }
            res = res.dup; // Copy to D-managed memory because 'tv' is about to be destroyed
        }

        return res;
    }
}

//! @brief It is a reference to a SCITER_VALUE. It is own value.
struct SciterValueView
{
    private SciterValueConstView _constView;

    @property public SciterValueConstView constView() const nothrow pure @nogc
    {
        return _constView;
    }

    alias constView this;

    @property SCITER_VALUE* raw() nothrow @nogc
    {
        return cast(SCITER_VALUE*) _constView.raw;
    }

    @property const(SCITER_VALUE)* raw() const nothrow @nogc
    {
        return _constView.raw;
    }

    SciterValueConstView opCast() const nothrow @nogc
    {
        return _constView;
    }

    private void clear() @nogc
    {
        sciterApi().ValueClear(raw);
    }

    this() @disable;

    private this(ref const(SCITER_VALUE) value) nothrow @nogc
    {
        _constView = SciterValueConstView(value);
    }

    this(SCITER_VALUE* value)
    {
        ensureSciterValueIsValid(value);
        _constView = SciterValueConstView(value);
    }

    this(SciterValueView value) nothrow @nogc
    {
        _constView = value._constView;
    }

    /*this(ref SciterValue value) nothrow @nogc
    {
        _constView = *value.raw;
    }*/

    /// 
    /// opEquals() methods
    ///

    bool opEquals(in const(SciterValueConstView) other) const nothrow @nogc
    {
        return _constView == other;
    }

    bool opEquals(in const(SciterValueView) other) const nothrow @nogc
    {
        return _constView == other._constView;
    }

    /// 
    /// opAssign() methods
    ///

    //! @brief a special version of assign for internal use - we do not check if the value is valid.
    //! @note we do not check if the value is not valid.
    private void opAssign(ref const(SCITER_VALUE) other) nothrow @nogc
    {
        _constView = SciterValueConstView(other);
    }

    void opAssign(SCITER_VALUE* other)
    {
        _constView = SciterValueConstView(other);
    }

    void opAssign(SciterValueView other) nothrow @nogc
    {
        _constView = other._constView;
    }

    void opAssign(T)(auto ref const(T) other) @nogc
    {
        set(other);
    }

    /// 
    /// set() methods
    /// 

    void setArrayWithSize(size_t length) @nogc
    {
        sciterApi().ValueIntDataSet(raw, cast(int) length, VALUE_TYPE.T_ARRAY, 0);
    }

    static SCITER_VALUE createUndefinedDescriptor() @nogc
    {
        SCITER_VALUE initValue;
        //initValue.t = VALUE_TYPE.T_UNDEFINED;
        return initValue;
    }

    static SCITER_VALUE createNothingDescriptor() @nogc
    {
        SCITER_VALUE initValue;
        initValue.t = VALUE_TYPE.T_UNDEFINED;
        initValue.u = VALUE_UNIT_UNDEFINED.UT_NOTHING;
        return initValue;
    }

    static SCITER_VALUE createNullDescriptor() @nogc
    {
        SCITER_VALUE initValue;
        initValue.t = VALUE_TYPE.T_NULL;
        return initValue;
    }

    void setUndefined() @nogc
    {
        clear();
        *raw = createUndefinedDescriptor();
    }

    void setNull() @nogc
    {
        clear();
        *raw = createNullDescriptor();
    }

    void setNothing() @nogc
    {
        clear();
        *raw = createNothingDescriptor();
    }

    void set(T : SCITER_VALUE)(in T value) @nogc
    {
        sciterApi().ValueCopy(raw, &value);
    }

    void set(T : SciterValue)(in T value) @nogc
    {
        sciterApi().ValueCopy(raw, value.raw);
    }

    void set(in SciterValueView value) @nogc
    {
        sciterApi().ValueCopy(raw, value.raw);
    }

    void set(in SciterValueConstView value) @nogc
    {
        sciterApi().ValueCopy(raw, value.raw);
    }

    void set(T : const(char)[])(in T value)
    {
        const auto utf16 = value.toUTF16();
        sciterApi().ValueStringDataSet(raw, utf16.ptr, cast(UINT) utf16.length, 0);
    }

    void set(T : const(wchar)[])(in T value) @nogc
    {
        sciterApi().ValueStringDataSet(raw, value.ptr, cast(UINT) value.length, 0);
    }

    void set(T : const(ubyte)[])(in T value) @nogc
    {
        sciterApi().ValueBinaryDataSet(raw, value.ptr, cast(UINT) value.length, VALUE_TYPE.T_BYTES, 0);
    }

    void set(T : int)(in T value) @nogc
    {
        sciterApi().ValueIntDataSet(raw, value, VALUE_TYPE.T_INT, 0);
    }

    void set(T : uint)(in T value) @nogc
    {
        sciterApi().ValueIntDataSet(raw, cast(int) value, VALUE_TYPE.T_INT, 0);
    }

    void set(T : long)(in T value) @nogc
    {
        sciterApi().ValueInt64DataSet(raw, value, VALUE_TYPE.T_BIG_INT, 0);
    }

    void set(T : ulong)(in T value) @nogc
    {
        sciterApi().ValueInt64DataSet(raw, cast(long) value, VALUE_TYPE.T_BIG_INT, 0);
    }

    void set(T : float)(in T value) @nogc
    {
        sciterApi().ValueFloatDataSet(raw, cast(double) value, VALUE_TYPE.T_FLOAT, 0);
    }

    void set(T : double)(in T value) @nogc
    {
        sciterApi().ValueFloatDataSet(raw, value, VALUE_TYPE.T_FLOAT, 0);
    }

    void set(T : bool)(in T value) @nogc
    {
        sciterApi().ValueIntDataSet(raw, value ? 1 : 0, VALUE_TYPE.T_BOOL, 0);
    }

    void set(T : void*)(in T value) @nogc
    {
        // For pointers, if ValuePointerDataSet is missing, we use ValueInt64DataSet as a handle
        sciterApi().ValueInt64DataSet(raw, cast(long) value, VALUE_TYPE.T_BIG_INT, 0);
    }

    void set(T : const(void)*)(in T value) @nogc
    {
        // For pointers, if ValuePointerDataSet is missing, we use ValueInt64DataSet as a handle
        sciterApi().ValueInt64DataSet(raw, cast(long) value, VALUE_TYPE.T_BIG_INT, 0);
    }
}

struct SciterValue
{
    private SCITER_VALUE _value;

    alias view this; // copy proprties and methods from 'view' property

    @property public SciterValueView view() nothrow @nogc
    {
        return SciterValueView(_value); // use special (nothrow) constructor
    }

    @property public SciterValueConstView view() const nothrow @nogc
    {
        return SciterValueConstView(_value); // use special (nothrow) constructor
    }

    private void init() @nogc
    {
        sciterApi().ValueInit(&_value);
    }

    private void clear() @nogc
    {
        view.clear();
    }

    static SciterValue makeUndefined() @nogc
    {
        return SciterValue(SciterValueView.createUndefinedDescriptor(), CaptureOwnership.init);
    }

    static SciterValue makeNull() @nogc
    {
        return SciterValue(SciterValueView.createNullDescriptor(), CaptureOwnership.init);
    }

    static SciterValue makeNothing() @nogc
    {
        return SciterValue(SciterValueView.createNothingDescriptor(), CaptureOwnership.init);
    }

    //! @note creates array of UNDEFINED SciterValues
    static SciterValue makeArrayWithSize(size_t length) @nogc
    {
        SciterValue v = makeUndefined();
        v.setArrayWithSize(length);
        return v;
    }

    //! @note creates SciterValue with array of values
    static SciterValue makeArray(T...)(T args)
    {
        SciterValue v = makeUndefined();
        v.setArrayWithSize(args.length);
        foreach (i, arg; args)
        {
            SciterValue v2 = arg;
            sciterApi().ValueNthElementValueSet(&v._value, cast(int) i, &v2._value);
        }
        return v;
    }

    static SciterValue makeMap()
    {
        SciterValue v = makeUndefined();
        sciterApi().ValueIntDataSet(&v._value, INT(0), VALUE_TYPE.T_MAP, 0);
        return v;
    }

    // returns string representing error.
    // if such value is used as a return value from native function
    // the script runtime will throw an error in script rather than returning that value.
    static SciterValue makeError(const(wchar)[] str)
    {
        SciterValue v = makeUndefined();
        if (str.length == 0)
            return v;

        sciterApi().ValueStringDataSet(&v._value, str.ptr, cast(UINT) str.length, VALUE_UNIT_TYPE_STRING
                .UT_STRING_ERROR);
        return v;
    }

    //this() @disable;

    struct CaptureOwnership
    {
    }

    private this(in const(SCITER_VALUE) other, CaptureOwnership) @nogc
    {
        _value = other;
    }

    private this(const(SCITER_VALUE)* other) @nogc
    {
        init(); // probably this is not needed
        set(*other);
    }

    this(T)(in T other)
    {
        init(); // probably this is not needed
        set(other);
    }

    ~this() @nogc
    {
        clear();
    }

    this(scope ref const(SciterValue) other) @nogc
    {
        init();
        sciterApi().ValueCopy(&_value, &other._value);
    }

    // copy of lvalue objects
    void opAssign(scope ref const(SciterValue) other) @nogc
    {
        if (!isSame(&_value, &other._value))
        {
            sciterApi().ValueCopy(&_value, &other._value);
        }
    }

    // copy rvalue objects (copy & swap for temporary objects)
    void opAssign(scope SciterValue other) @nogc
    {
        import std.algorithm.mutation : swap;

        swap(this._value, other._value);
    }

    void opAssign(T)(in T value) if (!is(T == SciterValue))
    {
        view.set(value);
    }

    // We still need to expose some methods that alias this might not propagate perfectly 
    // depending on constness or if they are templates.
    // Actually, alias this should handle it. Let's see.

    @property auto raw() inout nothrow @nogc
    {
        return &_value;
    }

    bool opEquals(in SciterValue other) const nothrow @nogc
    {
        return view.opEquals(other.view);
    }
}

struct AsArrayView
{
    private SCITER_VALUE* _value;

    this() @disable;

    this(SCITER_VALUE* v)
    {
        _value = v;
        ensureIsArray();
    }

    this(ref SciterValue v)
    {
        _value = v.raw;
        ensureIsArray();
    }

    private void ensureIsArray() const
    {
        if (!isArray())
            throw new Exception("Value is not an array");
    }

    bool isArray() const nothrow @nogc
    {
        return _value.t == VALUE_TYPE.T_ARRAY;
    }

    bool isArrayLike() const nothrow
    {
        return _value.t == VALUE_TYPE.T_ARRAY || (_value.t == VALUE_TYPE.T_OBJECT && _value.u == VALUE_UNIT_TYPE_OBJECT
                .UT_OBJECT_ARRAY);
    }

    // if it is an array or map returns number of elements there, otherwise - 0
    // if it is a function - returns number of arguments
    @property size_t length() const nothrow @nogc
    {
        int n = 0;
        sciterApi().ValueElementsCount(_value, &n);
        return cast(size_t) n;
    }
    // if it is an array - returns nth element
    // if it is a map - returns nth value of the map
    // if it is a function - returns nth argument
    // otherwise it returns undefined value
    SciterValue at(int n) const
    {
        SciterValue result = SciterValue.makeUndefined();
        sciterApi().ValueNthElementValue(_value, n, &result._value);
        return result;
    }

    SciterValue opIndex(size_t index) const
    {
        return at(cast(int) index);
    }

    void opIndex(size_t index, const ref SciterValue value)
    {
        sciterApi().ValueNthElementValueSet(_value, cast(int) index, &value._value);
    }

    void opIndex(T)(size_t index, in T value) if (!is(T : SciterValue))
    {
        SciterValue sciterValue = value;
        opIndex(index, sciterValue);
    }

    void append(const ref SciterValue value)
    {
        sciterApi().ValueNthElementValueSet(_value, cast(int) length(), &value._value);
    }

    void append(T)(in T value) if (!is(T : SciterValue))
    {
        SciterValue sciterValue = value;
        append(sciterValue);
    }

    void enumerate(bool delegate(in SciterValueView pkey, in SciterValueView pval) cb) const
    {
        struct CallbackData
        {
            bool delegate(in SciterValueView, in SciterValueView) callback;
        }

        extern (C) SBOOL nativeCb(void* param, const(SCITER_VALUE)* pkey, const(SCITER_VALUE)* pval)
        {
            auto data = cast(CallbackData*) param;
            SciterValueView key = cast(SCITER_VALUE*) pkey; // remove const
            SciterValueView val = cast(SCITER_VALUE*) pval; // remove const
            return data.callback(key, val) ? 1 : 0;
        }

        CallbackData data = CallbackData(cb);
        sciterApi().ValueEnumElements(_value, &nativeCb, cast(void*)&data);
    }

    int opApply(scope int delegate(SciterValue) dg)
    {
        int result = 0;
        for (int i = 0; i < cast(int) length(); i++)
        {
            result = dg(at(i));
            if (result)
                break;
        }
        return result;
    }

    int opApply(scope int delegate(size_t, SciterValue) dg)
    {
        int result = 0;
        for (int i = 0; i < cast(int) length(); i++)
        {
            result = dg(cast(size_t) i, at(i));
            if (result)
                break;
        }
        return result;
    }
}

struct AsMapView
{
    private SCITER_VALUE* _value;

    this() @disable;

    this(SCITER_VALUE* v)
    {
        _value = v;
        ensureIsMap();
    }

    this(ref SciterValue v)
    {
        _value = v.raw;
        ensureIsMap();
    }

    private void ensureIsMap() const
    {
        if (!isMap())
            throw new Exception("Value is not a map");
    }

    bool isMap() const nothrow @nogc
    {
        return _value.t == VALUE_TYPE.T_MAP;
    }

    bool isMapLike() const nothrow @nogc
    {
        return _value.t == VALUE_TYPE.T_MAP ||
            (_value.t == VALUE_TYPE.T_OBJECT && _value.u == VALUE_UNIT_TYPE_OBJECT.UT_OBJECT_OBJECT);
    }

    // if it is a map returns number of elements there, otherwise - 0
    @property size_t length() const nothrow @nogc
    {
        int n = 0;
        sciterApi().ValueElementsCount(_value, &n);
        return cast(size_t) n;
    }
    // if it is a map - returns nth key
    // if it is a function - returns nth argument
    // otherwise it returns undefined value
    SciterValue at(SciterValue key) const
    {
        SciterValue result = SciterValue.makeUndefined();
        sciterApi().ValueGetValueOfKey(_value, key.raw, &result._value);
        return result;
    }
}

@("SciterValue")
unittest
{
    // Test default constructor
    {
        SciterValue v; // static initialized to .init (all zeros)
        assert(v.isUndefined());

        SciterValue v2 = SciterValue.makeUndefined();
        assert(v2.isUndefined());
        assert(v == v2);
    }

    //
    // Test initialization and basic types
    // 

    {

        SciterValue v = SciterValue(42);
        assert(v.isInt());
        int i;
        assert(v.tryGet(i));
        assert(i == 42);
        assert(v.to!int() == 42);
    }

    {

        SciterValue v = SciterValue(true);
        assert(v.isBool());
        bool b;
        assert(v.tryGet(b));
        assert(b == true);
        assert(v.to!bool() == true);
    }

    {

        SciterValue v = SciterValue(3.14f);
        assert(v.isFloat());
        float f;
        assert(v.tryGet(f));
        assert(f > 3.13 && f < 3.15);
        assert(v.to!float() > 3.13 && v.to!float() < 3.15);

        double d;
        assert(v.tryGet(d));
        assert(d > 3.13 && d < 3.15);
        assert(v.to!double() > 3.13 && v.to!double() < 3.15);
    }

    // Test strings
    {

        SciterValue v = SciterValue("Hello Sciter");
        assert(v.isString());
        const(wchar)[] s;
        assert(v.tryGet(s));
        assert(s == "Hello Sciter"w);
        assert(v.to!(const(wchar)[])() == "Hello Sciter"w);

        // Simple comparison of slices
        //import std.conv : to;

        //assert(to!string(s) == "Hello Sciter");
    }

    // Test binary data
    {

        ubyte[] data = [1, 2, 3, 4];
        SciterValue v = SciterValue(data);
        assert(v.isBytes());
        const(ubyte)[] outData;
        assert(v.tryGet(outData));
        assert(outData == data);
        assert(v.to!(const(ubyte)[])() == data);
    }

    // Test null/nothing
    {

        SciterValue vUndef = SciterValue.makeUndefined(); // Default is Undefined
        SciterValue vNull = SciterValue.makeNull();
        SciterValue vNothing = SciterValue.makeNothing();

        assert(vUndef.isUndefined());
        assert(vNull.isNull());
        assert(vNothing.isNothing());
    }

    // Test comparison operators (ints)
    {

        SciterValue v1 = SciterValue(10);
        SciterValue v2 = SciterValue(20);
        SciterValue v3 = SciterValue(10);

        assert(v1 == v1);
        assert(v1 == v3);
        assert(v1 != v2);
    }

    // Test comparison operators (strings)
    {

        SciterValue s1 = SciterValue("abc");
        SciterValue s2 = SciterValue("def");
        SciterValue s3 = SciterValue("abc");

        assert(s1 == s1);
        assert(s1 == s3);
        assert(s1 != s2);
    }

    // Test comparison operators (different types)
    {

        SciterValue s1 = SciterValue("10");
        SciterValue s2 = SciterValue(10);
        SciterValue s3 = SciterValue(10);

        assert(s1 == s1);
        assert(s1 != s2);
        assert(s2 == s3);
    }

    // Test special values (null, undefined, nothing)
    {

        SciterValue vUndef = SciterValue.makeUndefined(); // Default is Undefined
        SciterValue vNull = SciterValue.makeNull();
        SciterValue vNothing = SciterValue.makeNothing();

        // Check against themselves and each other
        assert(vUndef == vUndef);
        assert(vNull == vNull);
        assert(vNothing == vNothing);

        assert(vUndef != vNull);
        assert(vNull != vNothing);
        assert(vUndef != vNothing);

        // Test setNull / setNothing
        SciterValue v = SciterValue.makeNull();
        assert(v == vNull);

        v = SciterValue.makeNothing();
        assert(v == vNothing);

        // Test comparison with values
        SciterValue vInt = SciterValue(10);
        assert(vInt != vNull);
        assert(vInt != vUndef);
        assert(vInt != vNothing);

        // Test lvalue assignment independence
        SciterValue vOrig = SciterValue(100);
        SciterValue vCopy = SciterValue.makeUndefined();
        vCopy = vOrig; // lvalue assignment
        assert(vCopy == vOrig);
        assert(vCopy.isInt() && vCopy.to!int == 100);
        assert(vOrig.isInt() && vOrig.to!int == 100); // vOrig must stay 100

        vCopy = 200; // change copy
        assert(vCopy.to!int == 200);
        assert(vOrig.to!int == 100); // vOrig must still be 100
    }

    // Test views interoperability
    {
        SciterValue vOrig = SciterValue(500);

        // Construction from SciterValueView
        {
            SciterValueView view = vOrig;
            SciterValue vCopy = SciterValue(view);
            assert(vCopy == vOrig);
            vCopy = 600;
            assert(vOrig.to!int == 500);
        }

        // Construction from SciterValueConstView
        {
            SciterValueConstView cview = vOrig;
            SciterValue vCopy = SciterValue(cview);
            assert(vCopy == vOrig);
            vCopy = 600;
            assert(vOrig.to!int == 500);
        }

        // Assignment from SciterValueView
        {
            SciterValueView view = vOrig;
            SciterValue vCopy = SciterValue.makeUndefined();
            vCopy = view;
            assert(vCopy == vOrig);
            vCopy = 600;
            assert(vOrig.to!int == 500);
        }

        // Assignment from SciterValueConstView
        {
            SciterValueConstView cview = vOrig;
            SciterValue vCopy = SciterValue.makeUndefined();
            vCopy = cview;
            assert(vCopy == vOrig);
            vCopy = 600;
            assert(vOrig.to!int == 500);
        }

        // Assignment from SciterValue itself
        {
            SciterValue orig = 100;
            SciterValue copy = orig.view;
            assert(copy == orig);
            copy = 600;
            assert(orig.to!int == 100);
            assert(copy.to!int == 600);
        }

        // Assignment to SciterValue.view
        {
            SciterValue orig = 100;
            SciterValueView view = orig.view;
            view = 200;
            assert(orig.to!int == 200);
            assert(view.to!int == 200);
        }

        // Assignment to SciterValue.view
        {
            SciterValue orig = 100;

            static assert(!__traits(compiles, orig.view = 200));
        }
    }

    // Test AsArrayView and enumerate
    {

        SciterValue v = SciterValue.makeArray(10, "abc", true);
        assert(v.isArray());

        auto arrView = AsArrayView(v);
        assert(arrView.length() == 3);
        assert(arrView[0].isInt());
        int i;
        assert(arrView[0].tryGet(i) && i == 10);
        assert(arrView[1].isString());
        const(wchar)[] s;
        import std.conv : to;

        assert(arrView[1].tryGet(s) && to!string(s) == "abc");
        assert(arrView[2].isBool());

        // Test enumerate
        int count = 0;
        arrView.enumerate((in SciterValueView key, in SciterValueView val) {
            count++;
            return true; // continue
        });
        assert(count == 3);

        // Test append
        arrView.append(42);
        assert(arrView.length() == 4);
        assert(arrView[3].isInt());
        assert(arrView[3].tryGet(i) && i == 42);

        // Test foreach
        int sum = 0;
        foreach (val; arrView)
        {
            if (val.isInt())
            {
                int valInt;
                if (val.tryGet(valInt))
                    sum += valInt;
            }
        }
        assert(sum == 10 + 42);

        size_t lastIdx = 0;
        foreach (idx, val; arrView)
        {
            lastIdx = idx;
        }
        assert(lastIdx == 3);
    }

    // Test toString memory safety (dangling pointer check)
    {

        SciterValue v_unsafe = SciterValue.makeArray(1, 2, 3);
        const(wchar)[] s_unsafe = v_unsafe.toString(VALUE_STRING_CVT_TYPE.CVT_JSON_LITERAL);

        // Trigger potential memory reuse
        foreach (k; 0 .. 1000)
        {
            SciterValue v2 = SciterValue.makeArray(0, 0, 0);
            v2.toString(VALUE_STRING_CVT_TYPE.CVT_JSON_LITERAL);
        }

        import std.conv : to;

        string result = to!string(s_unsafe);
        assert(result == "[1,2,3]", "toString() returned a dangling pointer! Result: " ~ result);
    }
}

@("SciterValueView: test c'tor and opEquals")
unittest
{
    SciterValue sv = SciterValue(42);
    SciterValue sv2 = SciterValue(43);

    /*
    //static assert(!__traits(compiles, { auto view = SciterValueView(sv); }));
    static assert(__traits(compiles, { auto view = SciterValueView(sv.view); }));
    static assert(!__traits(compiles, { SciterValueView view(sv.view); view = sv2; }));
    static assert(!__traits(compiles, { auto view = SciterValueConstView(sv); }));
    static assert(!__traits(compiles, {
            SciterValueConstView view(sv.view);
            view = sv2;
        }));
    */

    SciterValueView vViewA = sv.view;
    SciterValueView vViewB = sv.view;
    assert(vViewA == vViewB);

    // @todo: fix later
    /*
    vViewA = sv2; // should assign value of sv2 to sv
    assert(vViewA == SciterValue(43));
    sv2 = 44; // should not affect vViewA
    assert(vViewA == SciterValue(43));
    */
}
