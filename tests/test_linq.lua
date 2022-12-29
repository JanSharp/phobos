
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

---@generic T
local function assert_sequential_index_arg(linq_obj, func, callback)
  local i = 1
  local obj = func(linq_obj, function(value, j)
    assert.equals(i, j, "value is '"..tostring(value).."'")
    i = i + 1
    return callback(value, j)
  end)
  if type(obj) == "table" and obj.__is_linq then
    while obj.__iter() ~= nil do end
  end
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

  add_test("all with condition matching everything", function()
    local got = linq(get_test_strings()):all(function() return true end)
    assert.equals(true, got, "result of 'all'")
  end)

  add_test("all with condition matching 3 out of 4", function()
    local got = linq(get_test_strings()):all(function(value) return type(value) == "string" end)
    assert.equals(false, got, "result of 'all'")
  end)

  add_test("all with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_index_arg(obj, obj.all, function() return true end)
  end)

  add_test("any with condition matching nothing", function()
    local got = linq(get_test_strings()):any(function() return false end)
    assert.equals(false, got, "result of 'any'")
  end)

  add_test("any with condition matching 1 out of 4", function()
    local got = linq(get_test_strings()):any(function(value) return type(value) == "boolean" end)
    assert.equals(true, got, "result of 'any'")
  end)

  add_test("any with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_index_arg(obj, obj.any, function() return false end)
  end)

  add_test("append an array, self has known __count", function()
    local obj = linq(get_test_strings()):append{"hello", "world"}
    assert.equals(6, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("append an array, self has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:append{"hello", "world"}
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("append a linq object with known __count, self has known __count", function()
    local obj = linq(get_test_strings()):append(linq{"hello", "world"})
    assert.equals(6, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("append a linq object with unknown __count, self has known __count", function()
    local obj_to_append = linq{"hello", "world"}
    obj_to_append.__count = nil
    local obj = linq(get_test_strings()):append(obj_to_append)
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("append a linq object with known __count, self has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:append{"hello", "world"}
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("append a linq object with unknown __count, self has unknown __count", function()
    local obj_to_append = linq{"hello", "world"}
    obj_to_append.__count = nil
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:append(obj_to_append)
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"foo", "bar", false, "baz", "hello", "world"})
  end)

  add_test("average on object with known __count", function()
    local got = linq{1, 3, 5, 18, 32}:average()
    assert.equals((1 + 3 + 5 + 18 + 32) / 5, got, "result of 'average'")
  end)

  add_test("average on object with unknown __count", function()
    local obj = linq{1, 3, 5, 18, 32}
    obj.__count = nil
    local got = obj:average()
    assert.equals((1 + 3 + 5 + 18 + 32) / 5, got, "result of 'average'")
  end)

  add_test("average using selector", function()
    local got = linq(get_test_strings())
      :average(function(value) return type(value) == "string" and #value or 100 end)
    ;
    assert.equals((3 + 3 + 100 + 3) / 4, got, "result of 'average'")
  end)

  add_test("average using selector using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_index_arg(obj, obj.average, function() return 1 end)
  end)

  add_test("contains with a value that exists", function()
    local got = linq(get_test_strings()):contains("bar")
    assert.equals(true, got, "result of 'contains'")
  end)

  add_test("contains with a value that does not exist", function()
    local got = linq(get_test_strings()):contains(123)
    assert.equals(false, got, "result of 'contains'")
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

  add_test("distinct makes __count unknown", function()
    local obj = linq{}:distinct()
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("distinct with a triple duplicate and a double duplicate", function()
    local obj = linq{"hi", "hello", "hi", "bye", "bye", "hi"}:distinct()
    assert_iteration(obj, {"hi", "hello", "bye"})
  end)

  add_test("distinct with a selector", function()
    local obj = linq(get_test_strings())
      :distinct(function(value) return type(value) == "string" and value:sub(1, 2) or value end)
    ;
    assert_iteration(obj, {"fo", "ba", false})
  end)

  add_test("distinct with a selector using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_index_arg(obj, obj.distinct, function() return 1 end)
  end)

  add_test("except makes __count unknown", function()
    local obj = linq{}:except{}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("except with an array to exclude", function()
    local obj = linq(get_test_strings()):except{"foo", false}
    assert_iteration(obj, {"bar", "baz"})
  end)

  add_test("except with a linq object to exclude", function()
    local obj = linq(get_test_strings()):except(linq{"foo", "baz"})
    assert_iteration(obj, {"bar", false})
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
    assert.equals(expected_count, got_count, "__count before and after call to 'select'")
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
