
local framework = require("test_framework")
local assert = require("assert")

local serialize = require("serialize")

do
  local main_scope = framework.scope:new_scope("serialize")

  local function add_test(label, value, compare_pairs_iteration_order)
    if type(value) == "function" then
      value = value()
    end
    main_scope:add_test(label, function()
      local serialized = serialize(value)
      assert.contents_equals(
        value,
        assert.assert(load(serialized), "Serialized: "..serialized)(),
        "Serialized: "..serialized,
        {
          -- have to set this for tables with tables as keys,
          -- because there is no way to match them up otherwise.
          -- so yes, when testing with tables as keys you can only have 1 key in the whole table.
          compare_pairs_iteration_order = compare_pairs_iteration_order,
        }
      )
    end)
  end

  add_test("string", "string")
  add_test("special string", "\"\n\r\n\0\1\2\255")
  add_test("number", 100)
  add_test("huge number", 2 ^ 64)
  add_test("tiny number", 1 / 2 ^ 64)
  add_test("inf", 1/0)
  add_test("-inf", -1/0)
  add_test("nan", 0/0)
  add_test("one third", 1 / 3)
  add_test("true", true)
  add_test("false", false)
  add_test("nil", nil)
  add_test("empty table", {})
  add_test("array", {9, 8, 7, 6, 5, 4, 3, 2, 1, 0})
  add_test("number cache", {100, 100})
  add_test("string cache", {"foo", "foo"})
  add_test("array with holes", {9, 8, 7, 6, nil, 4, nil, nil, 1, 0})
  add_test("string as key", {foo = 3, bar = 2, baz = 1})
  add_test("boolean as key", {[false] = 1, [true] = 3})
  add_test("table as key", {[{}] = 1}, true)
  add_test("array and hash table", {6, 5, 4, 3, 2, 1, foo = 3, bar = 2, baz = 1})
  add_test("table referenced twice", function()
    local foo = {}
    return {
      bar = foo,
      baz = foo,
    }
  end)
  add_test("hash table back reference", function()
    local foo = {}
    foo.bar = foo
    return foo
  end)
  add_test("array with back reference", function()
    local foo = {}
    foo[1] = foo
    return foo
  end)
  add_test("array with back reference with value after", function()
    local foo = {}
    foo[1] = foo
    foo[2] = "bar"
    return foo
  end)
  add_test("back reference loop", function()
    local foo = {}
    local bar = {}
    foo.ref = bar
    bar.ref = foo
    return foo
  end)
  add_test("back reference used twice", function()
    local foo = {}
    foo.bar = foo
    foo.baz = foo
    return foo
  end)
  add_test("hash table and array back reference", function()
    local foo = {}
    foo[1] = foo
    foo.bar = foo
    return foo
  end)
  add_test("back reference as key", function()
    local foo = {}
    foo[foo] = 1
    return foo
  end, true)
end
