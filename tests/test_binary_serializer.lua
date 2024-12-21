
local framework = require("test_framework")
local assert = require("assert")
local pretty_print = require("pretty_print")

local binary = require("binary_serializer")
local nodes = require("nodes")

local tutil = require("testing_util")

do
  local main_scope = framework.scope:new_scope("binary_serializer")
  local prev_custom_string_pretty_printer
  main_scope.before_all = function()
    prev_custom_string_pretty_printer = pretty_print.custom_pretty_printers["string"]
    pretty_print.custom_pretty_printers["string"] = tutil.binary_pretty_printer
  end
  main_scope.after_all = function()
    pretty_print.custom_pretty_printers["string"] = prev_custom_string_pretty_printer
  end

  -- data sets used in both serializer and deserializer tests
  -- set in the serializer scope, reused for deserializer tests
  local space_optimized_uint_test_dataset
  local double_test_dataset

  do
    local serializer_scope = main_scope:new_scope("serializer")

    local function add_test(label, func)
      serializer_scope:add_test(label, function()
        local serializer = binary.new_serializer()
        local expected = func(serializer)
        assert.equals(expected, serializer:tostring())
        assert.equals(#expected, serializer:get_length(), "for get_length()")
      end)
    end

    local function add_out_of_bounds_test(label, name, min, value, max, func)
      serializer_scope:add_test(label, function()
        assert.errors(
          string.format(
            "Value out of bounds for %s, expected %d <= %d < %d.",
            name, min, value, max
          ),
          function()
            func(binary.new_serializer())
          end
        )
      end)
    end

    add_test("nothing", function() return "", 0 end)

    add_test("write raw", function(serializer)
      serializer:write_raw("foo")
      return "foo", 3
    end)

    add_test("write raw with explicit length", function(serializer)
      serializer:write_raw("foo", 3)
      return "foo", 3
    end)

    add_test("write twice", function(serializer)
      serializer:write_raw("foo")
      serializer:write_raw("bar")
      return "foobar", 6
    end)

    serializer_scope:add_test("initial binary_string", function()
      local serializer = binary.new_serializer("foo")
      assert.equals(3, serializer:get_length(), "for get_length()")
      assert.equals("foo", serializer:tostring())
    end)

    serializer_scope:add_test("initial binary_string and write raw", function()
      local serializer = binary.new_serializer("foo")
      serializer:write_raw("bar")
      assert.equals(6, serializer:get_length(), "for get_length()")
      assert.equals("foobar", serializer:tostring())
    end)

    add_test("uint8", function(serializer)
      serializer:write_uint8(100)
      return "\100", 1
    end)

    serializer_scope:add_test("uint8 non integer", function()
      local serializer = binary.new_serializer()
      assert.errors_with_pattern("Value must be an integer: '1.5%d*'%.", function()
        serializer:write_uint8(1.5)
      end)
    end)

    add_out_of_bounds_test("uint8 too small", "uint8", 0, -1, 2 ^ 8, function(serializer)
      serializer:write_uint8(-1)
    end)

    add_out_of_bounds_test("uint8 too big", "uint8", 0, 2 ^ 8 + 4, 2 ^ 8, function(serializer)
      serializer:write_uint8(2 ^ 8 + 4)
    end)

    add_out_of_bounds_test("uint8 barely too big", "uint8", 0, 2 ^ 8, 2 ^ 8, function(serializer)
      serializer:write_uint8(2 ^ 8)
    end)

    add_test("smallest uint8", function(serializer)
      serializer:write_uint8(0)
      return "\0", 1
    end)

    add_test("biggest uint8", function(serializer)
      serializer:write_uint8(2 ^ 8 - 1)
      return "\xff", 1
    end)

    -- Tested the out of bounds function, at this point it's just a matter of
    -- "is every function calling the out of bounds function with the right args".

    for _, data in ipairs{
      {name = "uint16", value = 0xf1f2, str = "\xf2\xf1", oob_max = 2 ^ 16},
      {name = "uint32", value = 0xf1f2f3f4, str = "\xf4\xf3\xf2\xf1", oob_max = 2 ^ 32},
      {
        name = "uint64",
        value = 0x00000000f1f2f3f4,
        str = "\xf4\xf3\xf2\xf1\x00\x00\x00\x00",
        oob_max = 2 ^ 53,
        oob_name = "uint64 (actually uint53)",
      },
    }
    do
      local name = data.name
      local byte_count = #data.str

      add_test(name, function(serializer)
        serializer["write_"..name](serializer, data.value)
        return data.str
      end)

      -- highest value in small form
      add_test("small small_"..name, function(serializer)
        serializer["write_small_"..name](serializer, 2 ^ 8 - 2)
        return "\xfe"
      end)

      -- lowest value in big form
      add_test("big small_"..name, function(serializer)
        serializer["write_small_"..name](serializer, 2 ^ 8 - 1)
        return "\xff\xff"..string.rep("\0", byte_count - 1)
      end)

      if name ~= "uint16" then
        -- highest value in medium form
        add_test("medium medium_"..name, function(serializer)
          serializer["write_medium_"..name](serializer, 2 ^ 16 - 2)
          return "\xfe\xff"
        end)

        -- lowest value in big form
        add_test("big medium_"..name, function(serializer)
          serializer["write_medium_"..name](serializer, 2 ^ 16 - 1)
          return "\xff\xff\xff\xff"..string.rep("\0", byte_count - 2)
        end)
      end

      add_out_of_bounds_test(name.." out of bounds",
        data.oob_name or name, 0, -1, data.oob_max,
        function(serializer)
          serializer["write_"..name](serializer, -1)
        end
      )
    end

    add_test("biggest uint64", function(serializer)
      serializer:write_uint64(2 ^ 53 - 1)
      return "\xff\xff\xff\xff\xff\xff\x1f\x00", 8
    end)

    add_test("size_t", function(serializer)
      serializer:write_size_t(0x001ff1f2f3f4f5f6)
      return "\xf6\xf5\xf4\xf3\xf2\xf1\x1f\x00", 8
    end)

    add_out_of_bounds_test("size_t out of bounds",
      "uint64 (actually uint53)", 0, -1, 2 ^ 53,
      function(serializer)
        serializer:write_size_t(-1)
      end
    )

    -- this dataset is also used for deserializer tests
    space_optimized_uint_test_dataset = {
      {label = "zero", value = 0, serialized = "\0"},
      {label = "max 1 bit value", value = 1, serialized = "\1"},
      {label = "max 7 bit value", value = 0x7f, serialized = "\x7f"},
      {label = "max 8 bit value", value = 0xff, serialized = "\xff\x01"},
      {label = "max 21 bit value", value = 0x1fffff, serialized = "\xff\xff\x7f"},
      {label = "max 53 bit value", value = 2 ^ 53 - 1, serialized = "\xff\xff\xff\xff\xff\xff\xff\x0f"},
    }

    for _, data in ipairs(space_optimized_uint_test_dataset) do
      add_test("space optimized uint "..data.label, function(serializer)
        serializer:write_uint_space_optimized(data.value)
        return data.serialized, #data.serialized
      end)
    end

    add_out_of_bounds_test("space optimized uint out of bounds",
      "space optimized uint (up to 53 bits)", 0, -1, 2 ^ 53,
      function(serializer)
        serializer:write_uint_space_optimized(-1)
      end
    )

    -- this dataset is also used for deserializer tests
    double_test_dataset = {
      -- site used for learning, even if it's just 32 bit floats:
      -- https://www.h-schmidt.net/FloatConverter/IEEE754.html
      -- the comments use big endian, the actual strings are written in little endian
      -- 0 is all 0s. Thank you IEEE754 <3
      {label = "zero", value = 0, serialized = "\x00\x00\x00\x00\x00\x00\x00\x00"},
      -- the next 3 use an exponent of 0, which is achieved by setting the entire exponent to 1s,
      -- except the highest bit to 0. for example: 0011 1111  1111 0000 ... 0000 0000
      {label = "one", value = 1, serialized = "\x00\x00\x00\x00\x00\x00\xf0\x3f"},
      {label = "one and one quarter", value = 1.25, serialized = "\x00\x00\x00\x00\x00\x00\xf4\x3f"},
      {label = "negative one", value = -1, serialized = "\x00\x00\x00\x00\x00\x00\xf0\xbf"},
      -- the first 2 bytes: 0100 0011  0011 0000 - to make an exponent of 52
      {label = "huge number", value = 2 ^ 52 + 1, serialized = "\x01\x00\x00\x00\x00\x00\x30\x43"},
      -- the entire exponent set to 1s and at least 1 bit in the mantissa is a 1...
      -- or for simplicity just set all of them to 1s, including the sign bit
      {label = "nan", value = 0/0, serialized = "\xff\xff\xff\xff\xff\xff\xff\xff"},
      -- the entire exponent filled with 1s
      {label = "inf", value = 1/0, serialized = "\x00\x00\x00\x00\x00\x00\xf0\x7f"},
      -- same here, but with sign bit
      {label = "negative inf", value = -1/0, serialized = "\x00\x00\x00\x00\x00\x00\xf0\xff"},
    }

    for _, data in ipairs(double_test_dataset) do
      add_test("double "..data.label, function(serializer)
        serializer:write_double(data.value)
        return data.serialized, 8
      end)
    end

    add_test("nil string", function(serializer)
      serializer:write_string(nil)
      return "\0\0", 1
    end)

    add_test("empty string", function(serializer)
      serializer:write_string("")
      return "\1\0", 1
    end)

    add_test("foo string", function(serializer)
      serializer:write_string("foo")
      return "\4\0foo", 4
    end)

    add_test("nil lua string", function(serializer)
      serializer:write_lua_string(nil)
      return "\0\0\0\0\0\0\0\0", 8
    end)

    add_test("empty lua string", function(serializer)
      serializer:write_lua_string("")
      return "\1\0\0\0\0\0\0\0\0", 8 + 1
    end)

    add_test("foo lua string", function(serializer)
      serializer:write_lua_string("foo")
      return "\4\0\0\0\0\0\0\0foo\0", 8 + 4
    end)

    add_test("boolean true", function(serializer)
      serializer:write_boolean(true)
      return "\1", 1
    end)

    add_test("boolean false", function(serializer)
      serializer:write_boolean(false)
      return "\0", 1
    end)

    add_test("nil constant", function(serializer)
      serializer:write_lua_constant(nodes.new_nil{})
      return "\0", 1
    end)

    add_test("boolean constant", function(serializer)
      serializer:write_lua_constant(nodes.new_boolean{value = true})
      return "\1\1", 2
    end)

    add_test("number constant", function(serializer)
      serializer:write_lua_constant(nodes.new_number{value = 0})
      return "\3\0\0\0\0\0\0\0\0", 1 + 8
    end)

    add_test("string constant", function(serializer)
      serializer:write_lua_constant(nodes.new_string{value = "hi"})
      return "\4\3\0\0\0\0\0\0\0hi\0", 1 + 8 + 3
    end)

    add_test("invalid constant", function(serializer)
      assert.errors(
        "Invalid Lua constant node type 'constructor', expected 'nil', 'boolean', 'number' or 'string'.",
        function()
          serializer:write_lua_constant(nodes.new_constructor{})
        end
      )
      return ""
    end)
  end

  do
    local deserializer_scope = main_scope:new_scope("deserializer")
    local prev_custom_number_pretty_printer
    deserializer_scope.before_all = function()
      prev_custom_number_pretty_printer = pretty_print.custom_pretty_printers["number"]
      pretty_print.custom_pretty_printers["number"] = function(value)
        return string.format("0x%x", value)
      end
    end
    deserializer_scope.after_all = function()
      pretty_print.custom_pretty_printers["number"] = prev_custom_number_pretty_printer
    end

    local function add_test(label, binary_string, func)
      deserializer_scope:add_test(label, function()
        local deserializer = binary.new_deserializer(binary_string)
        local data = func(deserializer) or {}
        if data[1] ~= nil and data[3] == nil then
          assert.equals(data[1], data[2])
        else
          for i = 1, #data, 2 do
            assert.equals(data[i], data[i + 1], "for value #"..i)
          end
        end
        assert.equals(binary_string, deserializer:get_string(), "for get_string()")
        assert.equals(#binary_string + 1, deserializer:get_index(), "for get_index()")
      end)
    end

    add_test("nothing", "", function() end)

    deserializer_scope:add_test("get_length", function()
      local deserializer = binary.new_deserializer("foo bar baz")
      assert.equals(11, deserializer:get_length(), "for get_length()")
    end)

    add_test("read raw", "foo", function(deserializer)
      return {"foo", deserializer:read_raw(3)}
    end)

    add_test("read raw twice", "fooBarr", function(deserializer)
      return {
        "foo", deserializer:read_raw(3),
        "Barr", deserializer:read_raw(4),
      }
    end)

    add_test("read bytes", "\0\1\2", function(deserializer)
      local zero, one, two = deserializer:read_bytes(3)
      return {
        0, zero,
        1, one,
        2, two,
      }
    end)

    add_test("read bytes twice", "\0\1\2", function(deserializer)
      local zero, one = deserializer:read_bytes(2)
      local two = deserializer:read_bytes(1)
      return {
        0, zero,
        1, one,
        2, two,
      }
    end)

    deserializer_scope:add_test("is_done", function()
      local deserializer = binary.new_deserializer("a")
      assert.equals(false, deserializer:is_done(), "before reading")
      deserializer:read_raw(1)
      assert.equals(true, deserializer:is_done(), "after reading")
    end)

    deserializer_scope:add_test("start index", function()
      local deserializer = binary.new_deserializer("foo", 4)
      assert.equals("foo", deserializer:get_string(), "for get_string()")
      assert.equals(4, deserializer:get_index(), "for get_index()")
    end)

    deserializer_scope:add_test("start index and read", function()
      local deserializer = binary.new_deserializer("foobar", 4)
      assert.equals("foobar", deserializer:get_string(), "for get_string()")
      assert.equals("bar", deserializer:read_raw(3), "for read after setting start index")
      assert.equals(7, deserializer:get_index(), "for get_index()")
    end)

    add_test("set and get allow_reading_past_end", "", function(deserializer)
      assert.equals(false, deserializer:get_allow_reading_past_end(), "as default value")
      deserializer:set_allow_reading_past_end(false)
      assert.equals(false, deserializer:get_allow_reading_past_end(), "after setting to false")
      deserializer:set_allow_reading_past_end(true)
      assert.equals(true, deserializer:get_allow_reading_past_end(), "after setting to true")
      assert.errors_with_pattern("Expected boolean for allow_reading_past_end, got.*", function()
        deserializer:set_allow_reading_past_end()
      end)
    end)

    deserializer_scope:add_test("read_raw past end while allow_reading_past_end is true", function()
      local deserializer = binary.new_deserializer("foo")
      deserializer:set_allow_reading_past_end(true)
      assert.equals("foo", deserializer:read_raw(10), "for reading")
      assert.equals(11, deserializer:get_index(), "for get_index()")
    end)

    deserializer_scope:add_test("read_bytes past end while allow_reading_past_end is true", function()
      local deserializer = binary.new_deserializer("\100\200")
      deserializer:set_allow_reading_past_end(true)
      local one, two, three = deserializer:read_bytes(8)
      assert.equals(100, one, "for the first byte")
      assert.equals(200, two, "for the second byte")
      assert.equals(nil, three, "for the third byte")
      assert.equals(9, deserializer:get_index(), "for get_index()")
    end)

    for _, name in ipairs{"read_raw", "read_bytes",} do
      deserializer_scope:add_test(name.." past end while allow_reading_past_end is false", function()
        local deserializer = binary.new_deserializer("foo")
        assert.errors("Attempt to read 10 bytes starting at index 1 where binary_string length is 3.", function()
          deserializer[name](deserializer, 10)
        end)
      end)
    end

    add_test("uint8", "\xf1", function(deserializer)
      return {0xf1, deserializer:read_uint8()}
    end)

    for _, data in ipairs{
      {name = "uint16", str = "\xf2\xf1", value = 0xf1f2},
      {name = "uint32", str = "\xf4\xf3\xf2\xf1", value = 0xf1f2f3f4},
      {name = "uint64", str = "\xf6\xf5\xf4\xf3\xf2\xf1\x1f\x00", value = 0x001ff1f2f3f4f5f6},
    }
    do
      local name = data.name
      local byte_count = #data.str

      add_test(name, data.str, function(deserializer)
        return {data.value, deserializer["read_"..name](deserializer)}
      end)

      -- highest value in small form
      add_test("small small_"..name, "\xfe", function(deserializer)
        return {2 ^ 8 - 2, deserializer["read_small_"..name](deserializer)}
      end)

      -- lowest value in big form
      add_test("big small_"..name, "\xff\xff"..string.rep("\0", byte_count - 1), function(deserializer)
        return {2 ^ 8 - 1, deserializer["read_small_"..name](deserializer)}
      end)

      if name ~= "uint16" then
        -- highest value in medium form
        add_test("medium medium_"..name, "\xfe\xff", function(deserializer)
          return {2 ^ 16 - 2, deserializer["read_medium_"..name](deserializer)}
        end)

        -- lowest value in big form
        add_test("big medium_"..name, "\xff\xff\xff\xff"..string.rep("\0", byte_count - 2), function(deserializer)
          return {2 ^ 16 - 1, deserializer["read_medium_"..name](deserializer)}
        end)
      end
    end

    add_test("uint64 7th byte out of bounds", "\x00\x00\x00\x00\x00\x00\x20\x00", function(deserializer)
      assert.errors_with_pattern("Unsupported.*uint64 %(actually uint53%).*2%s*^%s*53.", function()
        deserializer:read_uint64()
      end)
    end)

    add_test("uint64 8th byte out of bounds", "\x00\x00\x00\x00\x00\x00\x00\x01", function(deserializer)
      assert.errors_with_pattern("Unsupported.*uint64 %(actually uint53%).*2%s*^%s*53.", function()
        deserializer:read_uint64()
      end)
    end)

    add_test("size_t", "\x00\x00\x00\x00\x00\x01\x00\x00", function(deserializer)
      return {0x0000010000000000, deserializer:read_size_t()}
    end)

    -- reusing the dataset that was also used in serializer tests
    for _, data in ipairs(space_optimized_uint_test_dataset) do
      add_test("space optimized uint "..data.label, data.serialized, function(deserializer)
        return {data.value, deserializer:read_uint_space_optimized()}
      end)
    end

    -- reusing the dataset that was also used in serializer tests
    for _, data in ipairs(double_test_dataset) do
      add_test("double "..data.label, data.serialized, function(deserializer)
        return {data.value, deserializer:read_double()}
      end)
    end

    add_test("nil string", "\0\0", function(deserializer)
      assert.equals(nil, deserializer:read_string())
    end)

    add_test("empty string", "\1\0", function(deserializer)
      return {"", deserializer:read_string()}
    end)

    add_test("foo string", "\4\0foo", function(deserializer)
      return {"foo", deserializer:read_string()}
    end)

    add_test("nil lua string", "\0\0\0\0\0\0\0\0", function(deserializer)
      assert.equals(nil, deserializer:read_lua_string())
    end)

    add_test("empty lua string", "\1\0\0\0\0\0\0\0\0", function(deserializer)
      return {"", deserializer:read_lua_string()}
    end)

    add_test("foo lua string", "\4\0\0\0\0\0\0\0foo\0", function(deserializer)
      return {"foo", deserializer:read_lua_string()}
    end)

    add_test("true boolean", "\1", function(deserializer)
      return {true, deserializer:read_boolean()}
    end)

    add_test("false boolean", "\0", function(deserializer)
      return {false, deserializer:read_boolean()}
    end)

    add_test("nil constant", "\0", function(deserializer)
      assert.contents_equals(nodes.new_nil{}, deserializer:read_lua_constant())
    end)

    add_test("boolean constant", "\1\1", function(deserializer)
      assert.contents_equals(nodes.new_boolean{value = true}, deserializer:read_lua_constant())
    end)

    add_test("number constant", "\3\0\0\0\0\0\0\0\0", function(deserializer)
      assert.contents_equals(nodes.new_number{value = 0}, deserializer:read_lua_constant())
    end)

    add_test("string constant", "\4\3\0\0\0\0\0\0\0hi\0", function(deserializer)
      assert.contents_equals(nodes.new_string{value = "hi"}, deserializer:read_lua_constant())
    end)

    add_test("invalid nil string constant", "\4\0\0\0\0\0\0\0\0", function(deserializer)
      assert.errors("Lua constant strings must not be 'nil'.", function()
        deserializer:read_lua_constant()
      end)
    end)

    add_test("invalid constant type", "\5", function(deserializer)
      assert.errors_with_pattern("Invalid Lua constant type '5', expected.*", function()
        deserializer:read_lua_constant()
      end)
    end)
  end
end
