
local framework = require("test_framework")
local assert = require("assert")

local linq = require("linq")

local function get_test_strings()
  return {
    "foo",
    "bar",
    -- to catch if one of the iterators is using a test instead of a comparison with nil in a condition
    false,
    "baz",
  }
end

---@generic T
---@param linq_obj LinqObj|T[]
---@param expected_results T[]
local function assert_iteration(linq_obj, expected_results)
  local iter = linq_obj.__iter
  for i, expected in ipairs(expected_results) do
    local got = iter()
    assert.equals(expected, got, "value #"..i)
  end
  assert.equals(nil, iter(), "iterator returned another value after the end of expected values")
end

do
  local scope = framework.scope:new_scope("linq")

  local function add_test(name, func)
    scope:add_test(name, func)
  end

  add_test("creating a linq object from a table", function()
    local obj = linq(get_test_strings())
    assert_iteration(obj, get_test_strings())
  end)

  add_test("creating a linq object from an iterator function", function()
    local state = {some_data = true}
    local obj = linq(function(state_arg, value)
      assert.equals(state, state_arg, "state object for the iterator")
      if value == false then return end
      if (value or 0) >= 5 then return false end
      return (value or 0) + 1
    end, state, 2)
    assert_iteration(obj, {3, 4, 5, false})
  end)

  add_test("count on object with known __count", function()
    local obj = linq(get_test_strings())
    assert.equals(#get_test_strings(), obj:count(), "count")
  end)

  add_test("count on object with unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil -- means unknown
    assert.equals(#get_test_strings(), obj:count(), "count")
  end)

  add_test("iterate returns the correct iterator", function()
    local obj = linq{}
    local got_iter = obj:iterate()
    assert.equals(obj.__iter, got_iter, "iterator")
  end)

  add_test("select does not affect __count", function()
    local obj = linq(get_test_strings())
    local expected_count = obj.__count
    obj = obj:select(function(value) return value end)
    local got_count = obj.__count
    assert.equals(expected_count, got_count, "__count before and after call to select")
  end)

  add_test("select with selector performing substring", function()
    local obj = linq(get_test_strings())
      :select(function(value) return type(value) == "string" and value:sub(2, 3) or value end)
    ;
    assert_iteration(obj, {"oo", "ar", false, "az"})
  end)

  add_test("select with selector using index arg", function()
    local obj = linq(get_test_strings())
      :select(function(_, i) return i end)
    ;
    assert_iteration(obj, {1, 2, 3, 4})
  end)

  add_test("select_many makes __count unknown", function()
    local obj = linq{}:select_many(function(value) return {} end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("select_many with selector returning arrays", function()
    local obj = linq{"hi", "bye"}
      :select_many(function(value)
        local result = {}
        for i = 1, #value do
          result[i] = value:sub(i, i)
        end
        return result
      end)
    ;
    assert_iteration(obj, {"h", "i", "b", "y", "e"})
  end)

  add_test("select_many with selector returning linq objects", function()
    local obj = linq{"hi", "bye"}
      :select_many(function(value) return linq(value:gmatch(".")) end)
    ;
    assert_iteration(obj, {"h", "i", "b", "y", "e"})
  end)

  add_test("select_many with selector using the index arg", function()
    local obj = linq{"hi", "bye"}
      :select_many(function(value, i)
        local result = {}
        for j = 1, math.min(#value, i) do
          result[j] = value:sub(j, j)
        end
        return result
      end)
    ;
    assert_iteration(obj, {"h", "b", "y"})
  end)

  add_test("select_many with selector returning alternating arrays and linq objects", function()
    local obj = linq(get_test_strings())
      :select_many(function(value, i)
        if (i % 2) == 1 then
          return {value, value}
        else
          return linq{value}
        end
      end)
    ;
    assert_iteration(obj, {"foo", "foo", "bar", false, false, "baz"})
  end)

  add_test("take 0 values", function()
    local obj = linq(get_test_strings()):take(0)
    assert.equals(0, obj.__count, "internal __count after take")
    assert_iteration(obj, {})
  end)

  add_test("take 3 out of 4 values", function()
    local obj = linq(get_test_strings()):take(3)
    assert.equals(3, obj.__count, "internal __count after take")
    assert_iteration(obj, {"foo", "bar", false})
  end)

  add_test("take 5 out of 4 values", function()
    local obj = linq(get_test_strings()):take(5)
    assert.equals(4, obj.__count, "internal __count after take")
    assert_iteration(obj, get_test_strings())
  end)

  add_test("take 0 where object has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:take(0)
    assert.equals(0, obj.__count, "internal __count after take")
    assert_iteration(obj, {})
  end)

  add_test("take 3 where object has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:take(3)
    assert.equals(nil, obj.__count, "internal __count after take")
    assert_iteration(obj, {"foo", "bar", false})
  end)

  add_test("take_while makes __count unknown", function()
    local obj = linq(get_test_strings()):take_while(function() return true end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("take_while with condition taking nothing", function()
    local obj = linq(get_test_strings()):take_while(function() return false end)
    assert_iteration(obj, {})
  end)

  add_test("take_while with condition taking everything", function()
    local obj = linq(get_test_strings()):take_while(function() return true end)
    assert_iteration(obj, get_test_strings())
  end)

  add_test("take_while with condition using value", function()
    local obj = linq(get_test_strings()):take_while(function(value) return type(value) == "string" end)
    assert_iteration(obj, {"foo", "bar"})
  end)

  add_test("take_while with condition using index arg", function()
    local obj = linq(get_test_strings()):take_while(function(_, i) return i <= 3 end)
    assert_iteration(obj, {"foo", "bar", false})
  end)

  add_test("where makes __count unknown", function()
    local obj = linq(get_test_strings()):where(function() return true end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("where with condition taking nothing", function()
    local obj = linq(get_test_strings()):where(function() return false end)
    assert_iteration(obj, {})
  end)

  add_test("where with condition taking everything", function()
    local obj = linq(get_test_strings()):where(function() return true end)
    assert_iteration(obj, get_test_strings())
  end)

  add_test("where with condition matching 3 out of 4 values", function()
    local obj = linq(get_test_strings()):where(function(value) return type(value) == "string" end)
    assert_iteration(obj, {"foo", "bar", "baz"})
  end)

  add_test("where with condition using index arg", function()
    local obj = linq(get_test_strings()):where(function(_, i) return i ~= 2 end)
    assert_iteration(obj, {"foo", false, "baz"})
  end)
end
