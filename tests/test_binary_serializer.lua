
local framework = require("test_framework")
local assert = require("assert")
local pretty_print = require("pretty_print")

local binary = require("binary_serializer")
local nodes = require("nodes")

local tutil = require("testing_util")
nodes = tutil.wrap_nodes_constructors(nodes, assert.do_not_compare_flag)

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
          end,
          nil,
          true -- plain
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

    add_test("uint8", function(serializer)
      serializer:write_uint8(100)
      return "\100", 1
    end)

    serializer_scope:add_test("uint8 non integer", function()
      local serializer = binary.new_serializer()
      assert.errors("Value must be an integer: '1.5%d*'%.", function()
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

    local function add_uint_16_32_64_tests(name, value, str, oob_max, oob_name)
      local byte_count = #str

      add_test(name, function(serializer)
        serializer["write_"..name](serializer, value)
        return str
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
        oob_name or name, 0, -1, oob_max,
        function(serializer)
          serializer["write_"..name](serializer, -1)
        end
      )
    end

    add_uint_16_32_64_tests("uint16", 0xf1f2, "\xf2\xf1", 2 ^ 16)

    add_uint_16_32_64_tests("uint32", 0xf1f2f3f4, "\xf4\xf3\xf2\xf1", 2 ^ 32)

    add_uint_16_32_64_tests("uint64", 0x00000000f1f2f3f4, "\xf4\xf3\xf2\xf1\x00\x00\x00\x00", 2 ^ 53, "uint64 (actually uint53)")

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

    local function add_optimized_uint_test(label, value, result)
      add_test("space optimized uint "..label, function(serializer)
        serializer:write_uint_space_optimized(value)
        return result, #result
      end)
    end

    add_optimized_uint_test("zero", 0, "\0")
    add_optimized_uint_test("max 1 bit value", 1, "\1")
    add_optimized_uint_test("max 7 bit value", 0x7f, "\x7f")
    add_optimized_uint_test("max 8 bit value", 0xff, "\xff\x01")
    add_optimized_uint_test("max 21 bit value", 0x1fffff, "\xff\xff\x7f")
    add_optimized_uint_test("max 53 bit value", 2 ^ 53 - 1, "\xff\xff\xff\xff\xff\xff\xff\x0f")

    add_out_of_bounds_test("space optimized uint out of bounds",
      "space optimized uint (up to 53 bits)", 0, -1, 2 ^ 53,
      function(serializer)
        serializer:write_uint_space_optimized(-1)
      end
    )

    local function add_double_test(label, value, result)
      add_test("double "..label, function(serializer)
        serializer:write_double(value)
        return result, 8
      end)
    end

    -- the comments use big endian, the actual strings are written in little endian
    -- 0 is all 0s. Thank you IEEE754 <3
    add_double_test("zero", 0, "\x00\x00\x00\x00\x00\x00\x00\x00")
    -- the next 3 use an exponent of 0, which is achieved by setting the entire exponent to 1s,
    -- except the highest bit to 0. for example: 0011 1111  1111 0000 ... 0000 0000
    add_double_test("one", 1, "\x00\x00\x00\x00\x00\x00\xf0\x3f")
    add_double_test("one and one quarter", 1.25, "\x00\x00\x00\x00\x00\x00\xf4\x3f")
    add_double_test("negative one", -1, "\x00\x00\x00\x00\x00\x00\xf0\xbf")
    -- the first 2 bytes: 0100 0011  0011 0000 - to make an exponent of 52
    add_double_test("huge number", 2 ^ 52 + 1, "\x01\x00\x00\x00\x00\x00\x30\x43")
    -- the entire exponent set to 1s and at least 1 bit in the mantissa is a 1...
    -- or for simplicity just set all of them to 1s, including the sign bit
    add_double_test("nan", 0/0, "\xff\xff\xff\xff\xff\xff\xff\xff")
    -- the entire exponent filled with 1s
    add_double_test("inf", 1/0, "\x00\x00\x00\x00\x00\x00\xf0\x7f")
    -- same here, but with sign bit
    add_double_test("negative inf", -1/0, "\x00\x00\x00\x00\x00\x00\xf0\xff")

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
        "Invalid Lua constant node type 'constructor', expected.*",
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
        if data[1] ~= nil and not data[3] ~= nil then
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

    add_test("uint8", "\xf1", function(deserializer)
      return {0xf1, deserializer:read_uint8()}
    end)

    local function add_uint_16_32_64_tests(name, str, value)
      local byte_count = #str

      add_test(name, str, function(deserializer)
        return {value, deserializer["read_"..name](deserializer)}
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

    add_uint_16_32_64_tests("uint16", "\xf2\xf1", 0xf1f2)

    add_uint_16_32_64_tests("uint32", "\xf4\xf3\xf2\xf1", 0xf1f2f3f4)

    add_uint_16_32_64_tests("uint64", "\xf6\xf5\xf4\xf3\xf2\xf1\x1f\x00", 0x001ff1f2f3f4f5f6)

    add_test("uint64 7th byte out of bounds", "\x00\x00\x00\x00\x00\x00\x20\x00", function(deserializer)
      assert.errors("Unsupported.*uint64 %(actually uint53%).*2%s*^%s*53.", function()
        deserializer:read_uint64()
      end)
    end)

    add_test("uint64 8th byte out of bounds", "\x00\x00\x00\x00\x00\x00\x00\x01", function(deserializer)
      assert.errors("Unsupported.*uint64 %(actually uint53%).*2%s*^%s*53.", function()
        deserializer:read_uint64()
      end)
    end)

    add_test("size_t", "\x00\x00\x00\x00\x00\x01\x00\x00", function(deserializer)
      return {0x0000010000000000, deserializer:read_size_t()}
    end)

    local function add_optimized_uint_test(label, str, result)
      add_test("space optimized uint "..label, str, function(deserializer)
        return {result, deserializer:read_uint_space_optimized()}
      end)
    end

    -- all of these numbers are the same ones used in for the serializer tests
    add_optimized_uint_test("zero", "\0", 0)
    add_optimized_uint_test("max 1 bit value", "\1", 1)
    add_optimized_uint_test("max 7 bit value", "\x7f", 0x7f)
    add_optimized_uint_test("max 8 bit value", "\xff\x01", 0xff)
    add_optimized_uint_test("max 21 bit value", "\xff\xff\x7f", 0x1fffff)
    add_optimized_uint_test("max 53 bit value", "\xff\xff\xff\xff\xff\xff\xff\x0f", 2 ^ 53 - 1)

    local function add_double_test(label, str, result)
      add_test("double "..label, str, function(deserializer)
        return {result, deserializer:read_double()}
      end)
    end

    -- all of these numbers are the same ones used in for the serializer tests
    -- comments are also copied from above

    -- the comments use big endian, the actual strings are written in little endian
    -- 0 is all 0s. Thank you IEEE754 <3
    add_double_test("zero", "\x00\x00\x00\x00\x00\x00\x00\x00", 0)
    -- the next 3 use an exponent of 0, which is achieved by setting the entire exponent to 1s,
    -- except the highest bit to 0. for example: 0011 1111  1111 0000 ... 0000 0000
    add_double_test("one", "\x00\x00\x00\x00\x00\x00\xf0\x3f", 1)
    add_double_test("one and one quarter", "\x00\x00\x00\x00\x00\x00\xf4\x3f", 1.25)
    add_double_test("negative one", "\x00\x00\x00\x00\x00\x00\xf0\xbf", -1)
    -- the first 2 bytes: 0100 0011  0011 0000 - to make an exponent of 52
    add_double_test("huge number", "\x01\x00\x00\x00\x00\x00\x30\x43", 2 ^ 52 + 1)
    -- the entire exponent set to 1s and at least 1 bit in the mantissa is a 1...
    -- or for simplicity just set all of them to 1s, including the sign bit
    add_double_test("nan", "\xff\xff\xff\xff\xff\xff\xff\xff", 0/0)
    -- the entire exponent filled with 1s
    add_double_test("inf", "\x00\x00\x00\x00\x00\x00\xf0\x7f", 1/0)
    -- same here, but with sign bit
    add_double_test("negative inf", "\x00\x00\x00\x00\x00\x00\xf0\xff", -1/0)

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
      assert.contents_equals({node_type = "nil"}, deserializer:read_lua_constant())
    end)

    add_test("boolean constant", "\1\1", function(deserializer)
      assert.contents_equals({node_type = "boolean", value = true}, deserializer:read_lua_constant())
    end)

    add_test("number constant", "\3\0\0\0\0\0\0\0\0", function(deserializer)
      assert.contents_equals({node_type = "number", value = 0}, deserializer:read_lua_constant())
    end)

    add_test("string constant", "\4\3\0\0\0\0\0\0\0hi\0", function(deserializer)
      assert.contents_equals({node_type = "string", value = "hi"}, deserializer:read_lua_constant())
    end)

    add_test("invalid nil string constant", "\4\0\0\0\0\0\0\0\0", function(deserializer)
      assert.errors("Lua constant strings must not be 'nil'%.", function()
        deserializer:read_lua_constant()
      end)
    end)

    add_test("invalid constant type", "\5", function(deserializer)
      assert.errors("Invalid Lua constant type '5', expected.*", function()
        deserializer:read_lua_constant()
      end)
    end)
  end
end
