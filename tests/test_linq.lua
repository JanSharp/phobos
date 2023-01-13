
local framework = require("test_framework")
local assert = require("assert")

local linq = require("linq")

---@return (string|boolean)[]
local function get_test_strings()
  return {
    "foo",
    "bar",
    -- to catch if one of the iterators is using a test instead of a comparison with nil in a condition
    false,
    "baz",
  }
end

local known_or_unknown_count_dataset = {
  {label = "known __count", knows_count = true, make_obj = function(values)
    return linq(values)
  end},
  {label = "unknown __count", knows_count = false, make_obj = function(values)
    local obj = linq(values)
    obj.__count = nil
    return obj
  end},
}

local array_or_obj_with_known_or_unknown_count_dataset = {
  {label = "an array", make_obj = function(values)
    return values
  end},
  {label = "a linq object with known __count", make_obj = function(values)
    return linq(values)
  end},
  {label = "a linq object with unknown __count", make_obj = function(values)
    local obj = linq(values)
    obj.__count = nil
    return obj
  end},
}

---@generic T
---@param linq_obj LinqObj|T[]
---@param expected_results T[]
local function assert_iteration(linq_obj, expected_results)
  local got_results = {}
  for value in linq_obj.__iter do
    got_results[#got_results+1] = value
  end
  assert.contents_equals(expected_results, got_results)
  return got_results
end

---@generic T
---@param linq_obj LinqObj|T[]
local function iterate(linq_obj)
  while linq_obj.__iter() ~= nil do end
end

---@param callback fun(assert_sequential: fun(value, i, description?), ...): ...
---@param start_index integer?
---@param step integer?
local function assert_sequential_factory(callback, start_index, step)
  local expected_i = start_index or 1
  step = step or 1
  return function(...)
    return callback(function(value, i, description)
      assert.equals(expected_i, i, "sequential index for value '"..tostring(value).."'"
        ..(description and " for "..description or "")
      )
      expected_i = expected_i + step
    end, ...)
  end
end

---uses `assert_sequential_factory`, so this is just a helper function for functions
---which only take a single parameter, the callback/selector function, which gets `value` and `i` as args
---@param start_index integer?
---@param step integer?
local function assert_sequential_helper(linq_obj, func, callback, start_index, step)
  local obj = func(linq_obj, assert_sequential_factory(function(assert_sequential, value, i)
    assert_sequential(value, i)
    return callback(value, i)
  end, start_index, step))
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
    assert_sequential_helper(obj, obj.all, function() return true end)
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
    assert_sequential_helper(obj, obj.any, function() return false end)
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
    assert_sequential_helper(obj, obj.average, function() return 1 end)
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
    assert_sequential_helper(obj, obj.distinct, function() return 1 end)
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

  add_test("except_by makes __count unknown", function()
    local obj = linq{}:except_by({}, function(value) return value end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("except_by with an array to exclude", function()
    local obj = linq(get_test_strings())
      :except_by(
        ({"f", false})--[=[@as (string|boolean)[]]=],
        function(value)
          return type(value) == "string" and value:sub(1, 1) or false
        end
      )
    ;
    assert_iteration(obj, {"bar", "baz"})
  end)

  add_test("except_by with a linq object to exclude", function()
    local obj = linq(get_test_strings())
      :except_by(linq{"o", "a"}--[=[@as (string|boolean)[]]=], function(value)
        return type(value) == "string" and value:sub(2, 2) or value
      end)
    ;
    assert_iteration(obj, {false})
  end)

  add_test("except_by with selector using index arg", function()
    local obj = linq(get_test_strings())
      :except_by({}, assert_sequential_factory(function(assert_sequential, value, i)
        assert_sequential(value, i)
        return value
      end))
    ;
    iterate(obj)
  end)

  add_test("except_lut is nearly identical to except", function()
    local obj = linq(get_test_strings()):except_lut{bar = true, [false] = true}
    assert_iteration(obj, {"foo", "baz"})
  end)

  add_test("except_lut_by is nearly identical to except_by", function()
    local obj = linq{"hi", "there", "friend"}:except_lut_by({[5] = true}, function(value) return #value end)
    assert_iteration(obj, {"hi", "friend"})
  end)

  add_test("first gets the first element", function()
    local got_value, got_index = linq(get_test_strings()):first()
    assert.equals("foo", got_value, "value result of 'first'")
    assert.equals(1, got_index, "index result of 'first'")
  end)

  add_test("first on an empty collection", function()
    local got_value, got_index = linq{}:first()
    assert.equals(nil, got_value, "value result of 'first'")
    assert.equals(nil, got_index, "index result of 'first'")
  end)

  add_test("first with condition matching a value that does exist", function()
    local got_value, got_index = linq(get_test_strings()):first(function(value) return value == "baz" end)
    assert.equals("baz", got_value, "value result of 'first'")
    assert.equals(4, got_index, "index result of 'first'")
  end)

  add_test("first with condition matching a value that does not exist", function()
    local got_value, got_index = linq(get_test_strings()):first(function() return false end)
    assert.equals(nil, got_value, "value result of 'first'")
    assert.equals(nil, got_index, "index result of 'first'")
  end)

  add_test("first with a condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.first, function() return false end)
  end)

  add_test("for_each with an action using index arg", function()
    local values = get_test_strings()
    local obj = linq(values)
    assert_sequential_helper(obj, obj.for_each, function(value, i)
      assert.equals(values[i], value, "value #"..i)
    end)
  end)

  add_test("group_by creating 2 groups", function()
    local obj = linq(get_test_strings())
      :group_by(function(value) return type(value) end)
    ;
    assert_iteration(obj, {
      {key = "string", count = 3, "foo", "bar", "baz"},
      {key = "boolean", count = 1, false},
    })
  end)

  add_test("group_by with selector using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.group_by, function() return "key" end)
  end)

  add_test("group_by makes __count unknown", function()
    local obj = linq(get_test_strings()):group_by(function() return "key" end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("group_join associates one inner (an array) to one outer", function()
    local obj = linq{{key = 10, value = "hello"}}
      :group_join(
        {{key = 10, inner_value = "world"}},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {{key = 10, inner_value = "world"}}},
    })
  end)

  add_test("group_join associates one inner (a linq object) to one outer", function()
    local obj = linq{{key = 10, value = "hello"}}
      :group_join(
        linq{{key = 10, inner_value = "world"}},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {{key = 10, inner_value = "world"}}},
    })
  end)

  add_test("group_join keeps outer without any corresponding inner", function()
    local obj = linq{{key = 10, value = "hello"}}
      :group_join(
        {},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {}},
    })
  end)

  add_test("group_join keeps multiple outer with the same key, assigning the same inner", function()
    local obj = linq{{key = 10, value = "hello"}, {key = 10, value = "world"}}
      :group_join(
        {{key = 10, inner_value = "foo"}},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    -- same reference of the inner value, but arrays around it are shallow copied
    local expected_inner = {key = 10, inner_value = "foo"}
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {expected_inner}},
      {key = 10, outer = {key = 10, value = "world"}, inner = {expected_inner}},
    })
  end)

  add_test("group_join ignores inner with key not used by any outer", function()
    local obj = linq{{key = 10, value = "hello"}}
      :group_join(
        {{key = 20, inner_value = "world"}},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {}},
    })
  end)

  add_test("group_join groups multiple inner with outer", function()
    local obj = linq{{key = 10, value = "hello"}}
      :group_join(
        {{key = 10, inner_value = "foo"}, {key = 10, inner_value = "bar"}},
        function(inner) return inner.key end,
        function(outer) return outer.key end
      )
    ;
    assert_iteration(obj, {
      {key = 10, outer = {key = 10, value = "hello"}, inner = {
        {key = 10, inner_value = "foo"},
        {key = 10, inner_value = "bar"},
      }},
    })
  end)

  add_test("group_join inner (an array) key selector using index arg", function()
    local obj = linq{}
      :group_join(
        get_test_strings(),
        function(value) return value end,
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i)
          return value
        end)
      )
    ;
    iterate(obj)
  end)

  add_test("group_join inner (a linq object) key selector using index arg", function()
    local obj = linq{}
      :group_join(
        linq(get_test_strings()),
        function(value) return value end,
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i)
          return value
        end)
      )
    ;
    iterate(obj)
  end)

  add_test("group_join outer key selector using index arg", function()
    local obj = linq(get_test_strings())
      :group_join(
        {},
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i)
          return value
        end),
        function(value) return value end
      )
    ;
    iterate(obj)
  end)

  add_test("intersect with strings and 'false'", function()
    local obj = linq(get_test_strings()):intersect(get_test_strings())
    assert_iteration(obj, get_test_strings())
  end)

  add_test("intersect with empty collections", function()
    local obj = linq{}:intersect{}
    assert_iteration(obj, {})
  end)

  add_test("intersect makes __count unknown", function()
    local obj = linq{}:intersect{}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("intersect with array collection", function()
    local obj = linq{"hello", "world"}:intersect{"goodbye", "world"}
    assert_iteration(obj, {"world"})
  end)

  add_test("intersect with linq object collection", function()
    local obj = linq{"hello", "world"}:intersect(linq{"goodbye", "world"})
    assert_iteration(obj, {"world"})
  end)

  add_test("intersect with array collection with key_selector", function()
    local obj = linq{"hello", "world"}
      :intersect({"goodbye", "world"}, function(value) return value:sub(1, 3) end)
    ;
    assert_iteration(obj, {"world"})
  end)

  add_test("intersect with linq object collection with key_selector", function()
    local obj = linq{"hello", "world"}
      :intersect(linq{"goodbye", "world"}, function(value) return value:sub(1, 3) end)
    ;
    assert_iteration(obj, {"world"})
  end)

  add_test("iterate returns the correct iterator", function()
    local obj = linq{}
    local got_iter = obj:iterate()
    assert.equals(obj.__iter, got_iter, "iterator")
  end)

  add_test("last gets the last element", function()
    local got_value, got_index = linq(get_test_strings()):last()
    assert.equals("baz", got_value, "value result of 'last'")
    assert.equals(4, got_index, "index result of 'last'")
  end)

  add_test("last on an empty collection", function()
    local got_value, got_index = linq{}:last()
    assert.equals(nil, got_value, "value result of 'last'")
    assert.equals(nil, got_index, "index result of 'last'")
  end)

  add_test("last with condition matching a value that does exist", function()
    local got_value, got_index = linq(get_test_strings()):last(function(value) return value == "foo" end)
    assert.equals("foo", got_value, "value result of 'last'")
    assert.equals(1, got_index, "index result of 'last'")
  end)

  add_test("last with condition matching a value that does not exist", function()
    local got_value, got_index = linq(get_test_strings()):last(function() return false end)
    assert.equals(nil, got_value, "value result of 'last'")
    assert.equals(nil, got_index, "index result of 'last'")
  end)

  add_test("last with a condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.last, function() return false end, 4, -1)
  end)

  add_test("join makes __count unknown", function()
    local obj = linq{}
      :join(
        {},
        function(value) return value end,
        function(value) return value end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("join with an array inner collection", function()
    local obj = linq{"hello", "world"}
      :join(
        {"hi", "what", "hey"},
        function(value) return value:sub(1, 1) end,
        function(value) return value:sub(1, 1) end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    assert_iteration(obj, {
      {outer = "hello", inner = "hi"},
      {outer = "hello", inner = "hey"},
      {outer = "world", inner = "what"},
    })
  end)

  add_test("join with a linq object inner collection", function()
    local obj = linq{"hello", "world"}
      :join(
        linq{"hi", "what", "hey"},
        function(value) return value:sub(1, 1) end,
        function(value) return value:sub(1, 1) end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    assert_iteration(obj, {
      {outer = "hello", inner = "hi"},
      {outer = "hello", inner = "hey"},
      {outer = "world", inner = "what"},
    })
  end)

  add_test("join an outer without any corresponding inner drops the outer", function()
    local obj = linq{"foo"}
      :join(
        {},
        function(value) return value end,
        function(value) return value end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    assert_iteration(obj, {})
  end)

  add_test("join an inner without any corresponding outer drops the inner", function()
    local obj = linq{}
      :join(
        {"foo"},
        function(value) return value end,
        function(value) return value end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    assert_iteration(obj, {})
  end)

  add_test("join 2 outer and 2 inner all with the same key creates 4 results", function()
    local obj = linq{"bar", "baz"}
      :join(
        {"better", "best"},
        function(value) return value:sub(1, 1) end,
        function(value) return value:sub(1, 1) end,
        function(outer, inner) return {outer = outer, inner = inner} end
      )
    ;
    assert_iteration(obj, {
      {outer = "bar", inner = "better"},
      {outer = "bar", inner = "best"},
      {outer = "baz", inner = "better"},
      {outer = "baz", inner = "best"},
    })
  end)

  add_test("join with an array inner collection with all selectors using index arg", function()
    local obj = linq(get_test_strings())
      :join(
        get_test_strings(),
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i, "outer_key_selector")
          return value
        end),
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i, "inner_key_selector")
          return value
        end),
        assert_sequential_factory(function(assert_sequential, outer, inner, i)
          assert_sequential("outer: "..tostring(outer)..", inner: "..tostring(inner), i, "result_selector")
          return {outer = outer, inner = inner}
        end)
      )
    ;
    iterate(obj)
  end)

  add_test("join with a linq object inner collection with all selectors using index arg", function()
    local obj = linq(get_test_strings())
      :join(
        linq(get_test_strings()),
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i, "outer_key_selector")
          return value
        end),
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i, "inner_key_selector")
          return value
        end),
        assert_sequential_factory(function(assert_sequential, outer, inner, i)
          assert_sequential("outer: "..tostring(outer)..", inner: "..tostring(inner), i, "result_selector")
          return {outer = outer, inner = inner}
        end)
      )
    ;
    iterate(obj)
  end)

  add_test("max with 3 values", function()
    local got = linq{2, 1, 3}:max()
    assert.equals(3, got, "result of 'max'")
  end)

  add_test("max with 4 values using custom comparator", function()
    local function get_value(value)
      return type(value) == "string" and #value or 100
    end
    local got = linq(get_test_strings()):max(function(left, right)
      return get_value(left) > get_value(right)
    end)
    assert.equals(false, got, "result of 'max'")
  end)

  add_test("max with empty collection", function()
    local obj = linq{}
    assert.errors("Attempt to evaluate max value on an empty collection%.", function()
      obj:max()
    end)
  end)

  add_test("max_by with 4 values", function()
    local got = linq(get_test_strings()):max_by(function(value)
      return type(value) == "string" and #value or 0
    end)
    assert.equals("foo", got, "result of 'max_by'")
  end)

  add_test("max_by with 4 values using custom comparator", function()
    local got = linq(get_test_strings()):max_by(function(value)
      return type(value) == "string" and #value or 0
    end, function(left, right)
      -- 0 beats everything!
      if left == 0 then return true end
      if right == 0 then return false end
      return left > right
    end)
    assert.equals(false, got, "result of 'max_by'")
  end)

  add_test("max_by with empty collection", function()
    local obj = linq{}
    assert.errors("Attempt to evaluate max value on an empty collection%.", function()
      obj:max_by(function(value) return value end)
    end)
  end)

  add_test("max_by with selector using index arg", function()
    linq{1, 4, 2, 3, 10}:max_by(assert_sequential_factory(function(assert_sequential, value, i)
      assert_sequential(value, i)
      return value
    end))
  end)

  add_test("min with 3 values", function()
    local got = linq{2, 1, 3}:min()
    assert.equals(1, got, "result of 'min'")
  end)

  add_test("min with 4 values using custom comparator", function()
    local function get_value(value)
      return type(value) == "string" and #value or -100
    end
    local got = linq(get_test_strings()):min(function(left, right)
      return get_value(left) < get_value(right)
    end)
    assert.equals(false, got, "result of 'min'")
  end)

  add_test("min with empty collection", function()
    local obj = linq{}
    assert.errors("Attempt to evaluate min value on an empty collection%.", function()
      obj:min()
    end)
  end)

  add_test("min_by with 4 values", function()
    local got = linq(get_test_strings()):min_by(function(value)
      return type(value) == "string" and #value or 100
    end)
    assert.equals("foo", got, "result of 'min_by'")
  end)

  add_test("min_by with 4 values using custom comparator", function()
    local got = linq(get_test_strings()):min_by(function(value)
      return type(value) == "string" and #value or 100
    end, function(left, right)
      -- 100 beats everything!
      if left == 100 then return true end
      if right == 100 then return false end
      return left < right
    end)
    assert.equals(false, got, "result of 'min_by'")
  end)

  add_test("min_by with empty collection", function()
    local obj = linq{}
    assert.errors("Attempt to evaluate min value on an empty collection%.", function()
      obj:min_by(function(value) return value end)
    end)
  end)

  add_test("min_by with selector using index arg", function()
    linq{1, 4, 2, 3, 10}:min_by(assert_sequential_factory(function(assert_sequential, value, i)
      assert_sequential(value, i)
      return value
    end))
  end)

  add_test("prepend an array, self has known __count", function()
    local obj = linq(get_test_strings()):prepend{"hello", "world"}
    assert.equals(6, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("prepend an array, self has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:prepend{"hello", "world"}
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("prepend a linq object with known __count, self has known __count", function()
    local obj = linq(get_test_strings()):prepend(linq{"hello", "world"})
    assert.equals(6, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("prepend a linq object with unknown __count, self has known __count", function()
    local obj_to_prepend = linq{"hello", "world"}
    obj_to_prepend.__count = nil
    local obj = linq(get_test_strings()):prepend(obj_to_prepend)
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("prepend a linq object with known __count, self has unknown __count", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:prepend{"hello", "world"}
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("prepend a linq object with unknown __count, self has unknown __count", function()
    local obj_to_prepend = linq{"hello", "world"}
    obj_to_prepend.__count = nil
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:prepend(obj_to_prepend)
    assert.equals(nil, obj.__count, "internal __count")
    assert_iteration(obj, {"hello", "world", table.unpack(get_test_strings())})
  end)

  add_test("reverse with 0 values", function()
    local obj = linq{}:reverse()
    assert_iteration(obj, {})
  end)

  add_test("reverse with 4 values", function()
    local obj = linq(get_test_strings()):reverse()
    assert_iteration(obj, {"baz", false, "bar", "foo"})
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

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
      for _, data in ipairs{
        {label = "matching values", values = get_test_strings(), result = true},
        {label = "too few values", values = {"foo", "bar", false}, result = false},
        {label = "too many values", values = {"foo", "bar", false, "baz", "hello"}, result = false},
        {label = "mismatching values", values = {"foo", "nope", true, "yes"}, result = false},
      }
      do
        add_test("sequence_equal with "..outer.label.." with "..inner.label.." with "..data.label, function()
          local got = outer.make_obj(get_test_strings()):sequence_equal(inner.make_obj(data.values))
          assert.equals(data.result, got, "result of 'sequence_equal'")
        end)
      end
    end
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    local err_msg_prefix = "Expected a single value in the sequence, got "
    for _, data in ipairs{
      {label = "0 values", values = {}, error = outer.knows_count and "0" or "zero"},
      {label = "1 value", values = {"foo"}, error = nil},
      {label = "2 values", values = {"foo", "bar"}, error = outer.knows_count and "2" or "multiple"},
      {label = "3 values", values = {"foo", "bar", "baz"}, error = outer.knows_count and "3" or "multiple"},
    }
    do
      add_test("single with "..outer.label.." without condition with "..data.label, function()
        local obj = outer.make_obj(data.values)
        if data.error then
          assert.errors(err_msg_prefix..data.error.."%.", function()
            obj:single()
          end)
        else
          local got = obj:single()
          assert.equals(data.values[1], got, "result of 'single'")
        end
      end)
    end
  end

  for _, data in ipairs{
    {label = "0 matching values", error = "zero", condition = function() return false end},
    {label = "1 matching value", expected = "foo", condition = function(value) return value == "foo" end},
    {label = "2 matching values", error = "multiple", condition = function(value)
      return type(value) == "string" and value:sub(1, 1) == "b"
    end},
  }
  do
    add_test("single with condition with "..data.label, function()
      local obj = linq(get_test_strings())
      if data.error then
        assert.errors(
          "Expected a single value in the sequence to match the condition, got "..data.error.."%.",
          function()
            obj:single(data.condition)
          end
        )
      else
        local got = obj:single(data.condition)
        assert.equals(data.expected, got, "result of 'single'")
      end
    end)
  end

  add_test("single with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.single, function(value) return value == "baz" end)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {skip_count = 0, expected_count = 4, expected = get_test_strings()},
      {skip_count = 1, expected_count = 3, expected = {"bar", false, "baz"}},
      {skip_count = 3, expected_count = 1, expected = {"baz"}},
      {skip_count = 4, expected_count = 0, expected = {}},
      {skip_count = 5, expected_count = 0, expected = {}},
    }
    do
      add_test("skip "..data.skip_count.." out of 4 values, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):skip(data.skip_count)
        local expected_count = outer.knows_count and data.expected_count or nil
        assert.equals(expected_count, obj.__count, "internal __count after skip")
        assert_iteration(obj, data.expected)
      end)
    end
  end

  for _, data in ipairs{
    {skip_count = 0, expected = get_test_strings(), condition = function(value) return false end},
    {skip_count = 1, expected = {"bar", false, "baz"}, condition = function(value) return value == "foo" end},
    {skip_count = 3, expected = {"baz"}, condition = function(value) return value ~= "baz" end},
    {skip_count = 4, expected = {}, condition = function(value) return true end},
  }
  do
    add_test("skip_while "..data.skip_count.." out of 4 values", function()
      local obj = linq(get_test_strings()):skip_while(data.condition)
      assert_iteration(obj, data.expected)
    end)
  end

  add_test("skip_while with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.skip_while, function() return true end)
  end)

  add_test("skip_while makes __count unknown", function()
    local obj = linq(get_test_strings()):skip_while(function() return true end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
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
