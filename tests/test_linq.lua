
local framework = require("test_framework")
local assert = require("assert")

local linq = require("linq")

local util = require("util")
local ll = require("linked_list")
local stack = require("stack")

local function reverse_array(array)
  local result = {}
  local count = #array
  for i = count, 1, -1 do
    result[count - i + 1] = array[i]
  end
  return result
end

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
  {label = "an array", knows_count = true, make_obj = function(values)
    return values
  end},
  {label = "a linq object with known __count", knows_count = true, make_obj = function(values)
    return linq(values)
  end},
  {label = "a linq object with unknown __count", knows_count = false, make_obj = function(values)
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
  assert.contents_equals(expected_results, got_results, "results")

  local values_past_end = {}
  for i = 1, 10 do
    values_past_end[i] = linq_obj.__iter()
  end
  assert.contents_equals(
    {},
    values_past_end,
    "extra values returned by the iterator after it had already return nil before"
  )

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

  -- IMPORTANT: for these validation tests, the helper functions for parameter validation directly wrap the ...
  -- call to 'func' in an 'assert.errors' while the helper functions for sequence value or selector validation
  -- pass an 'assert_errors' function to 'func' to reduce the chance of misleading failed test error messages

  local function add_validation_test_internal(
    error_msg_template,
    linq_func_name,
    value_name,
    optional,
    func,
    use_number_instead_of_string
  )
    add_test(
      linq_func_name.." given a "..(use_number_instead_of_string and "number" or "string")
        .." as "..value_name.." errors",
      function()
        local value = use_number_instead_of_string and 132 or "hello world"
        assert.errors(
          util.format_interpolated(error_msg_template, {got = value}),
          function() func(value) end
        )
      end
    )

    add_test(
      linq_func_name.." given 'nil' as "..value_name
        ..(optional and " succeeds because it's optional" or " errors"),
      function()
        if optional then
          func(nil) -- should not error
        else
          assert.errors(
            util.format_interpolated(error_msg_template, {got = "nil"}),
            function() func(nil) end
          )
        end
      end
    )
  end

  local function add_function_validation_test(linq_func_name, func_name, optional, func)
    add_validation_test_internal(
      "Expected a function as the "..func_name..", got '{got}'.",
      linq_func_name,
      func_name,
      optional,
      func
    )
  end

  local function add_condition_validation_test(linq_func_name, optional, func)
    add_function_validation_test(linq_func_name, "condition", optional, func)
  end

  local function add_selector_validation_test(linq_func_name, optional, func)
    add_function_validation_test(linq_func_name, "selector", optional, func)
  end

  local function add_action_validation_test(linq_func_name, optional, func)
    add_function_validation_test(linq_func_name, "action", optional, func)
  end

  local function add_comparator_validation_test(linq_func_name, optional, func)
    add_function_validation_test(linq_func_name, "comparator", optional, func)
  end

  local function add_collection_validation_test(linq_func_name, collection_name, optional, func)
    add_validation_test_internal(
      "Expected a linq object or array as the "..collection_name..", got '{got}'.",
      linq_func_name,
      collection_name,
      optional,
      func
    )
  end

  local function add_value_validation_test_internal(linq_func_name, value_name, err_msg, func)
    add_test(linq_func_name.." given a 'nil' as the "..value_name.." value errors", function()
      assert.errors(err_msg, function() func(nil) end)
    end)
  end

  local function add_search_value_validation_test(linq_func_name, func)
    add_value_validation_test_internal(
      linq_func_name,
      "search",
      "Searching for a 'nil' value in a sequence is disallowed. \z
        A sequence cannot contain 'nil'.",
      func
    )
  end

  local function add_default_value_validation_test(linq_func_name, func)
    add_value_validation_test_internal(
      linq_func_name,
      "default",
      "The default value must not be 'nil'. \z
        A sequence cannot contain 'nil'.",
      func
    )
  end

  local function add_insert_value_validation_test(linq_func_name, func)
    add_value_validation_test_internal(
      linq_func_name,
      "insert",
      "Inserting a 'nil' value into a sequence is disallowed. \z
        A sequence cannot contain 'nil'.",
      func
    )
  end

  local function add_lut_validation_test(linq_func_name, func)
    add_validation_test_internal(
      "Expected a lookup table, got '{got}'.",
      linq_func_name,
      "lut",
      false,
      func
    )
  end

  local function add_number_validation_test(linq_func_name, include_zero, param_name, func)
    local error_msg_template = "Expected an integer greater than 0"..(include_zero and " or equal to" or "")
      .." as the "..param_name..", got '{got}'."
    add_validation_test_internal(
      error_msg_template,
      linq_func_name,
      param_name,
      false,
      func
    )

    add_test(linq_func_name.." given a negative number as "..param_name.." errors", function()
      assert.errors(
        util.format_interpolated(error_msg_template, {got = -1}),
        function() func(-1) end
      )
    end)

    add_test(
      linq_func_name.." given the number zero as "..param_name.." "
        ..(include_zero and "succeeds" or "errors"),
      function()
        if include_zero then
          func(0) -- should not error
        else
          assert.errors(
            util.format_interpolated(error_msg_template, {got = 0}),
            function() func(0) end
          )
        end
      end
    )
  end

  local function add_index_validation_test(linq_func_name, func, param_name)
    add_number_validation_test(linq_func_name, false, param_name or "index", func)
  end

  local function add_size_validation_test(linq_func_name, func)
    add_number_validation_test(linq_func_name, false, "size", func)
  end

  local function add_count_validation_test(linq_func_name, func)
    add_number_validation_test(linq_func_name, true, "count", func)
  end

  local function add_name_validation_test(linq_func_name, optional, func)
    add_validation_test_internal(
      "Expected a string as the name, got '{got}'.",
      linq_func_name,
      "name",
      optional,
      func,
      true
    )
  end

  local function add_track_liveliness_validation_test(linq_func_name, optional, func)
    add_validation_test_internal(
      "Expected a boolean for track_liveliness, got '{got}'.",
      linq_func_name,
      "name",
      optional,
      func,
      true
    )
  end

  ---@param func fun(value: any, assert_errors: fun(erroring_func: fun()))
  local function add_typed_sequence_value_validation_test(
    linq_func_name,
    label_infix,
    post_selection,
    expected_type,
    invalid_value,
    func
  )
    label_infix = label_infix and (" "..label_infix) or ""
    local function add_test_for_value(value)
      add_test(
        linq_func_name.." containing '"..tostring(value).."' in the sequence"..label_infix.." errors",
        function()
          if post_selection then
            func(value, function(erroring_func)
              assert.errors(
                "The selector for '"..linq_func_name.."' must return a "..expected_type.." \z
                  for each value in the sequence, but for one it returned '"..tostring(value).."'.",
                erroring_func
              )
            end)
          else
            func(value, function(erroring_func)
              assert.errors(
                "Every value in the sequence for '"..linq_func_name.."' \z
                  must be a "..expected_type..", but one is '"..tostring(value).."'.",
                erroring_func
              )
            end)
          end
        end
      )
    end
    add_test_for_value(invalid_value)
    if post_selection then
      add_test_for_value(nil)
    end
  end

  ---@param func fun(value: any, assert_errors: fun(erroring_func: fun()))
  local function add_sequence_number_validation_test(linq_func_name, label_infix, post_selection, func)
    add_typed_sequence_value_validation_test(
      linq_func_name,
      label_infix,
      post_selection,
      "number",
      "hello world",
      func
    )
  end

  ---@param func fun(value: any, assert_errors: fun(erroring_func: fun()))
  local function add_sequence_value_for_ordering_validation_test(
    linq_func_name,
    label_infix,
    ordering_definition_index,
    post_selection,
    func
  )
    label_infix = label_infix and (" "..label_infix) or ""
    local function add_test_for_value(value)
      add_test(
        linq_func_name.." containing '"..tostring(value).."' in the sequence"..label_infix.." errors",
        function()
          if post_selection then
            func(value, function(erroring_func)
              assert.errors(
              "The selector for an order function must return a number or a string \z
                for each value in the sequence, but for one it returned '"..tostring(value).."' \z
                (ordering definition index: "..ordering_definition_index..").",
              erroring_func
            )
            end)
          else
            func(value, function(erroring_func)
              assert.errors(
                "Every value in the sequence for an order function must be a number or a string, but one \z
                  is '"..tostring(value).."' (ordering definition index: "..ordering_definition_index..").",
                erroring_func
              )
            end)
          end
        end
      )
    end
    add_test_for_value(true)
    if post_selection then
      add_test_for_value(nil)
    end
  end

  ---@param func fun(assert_selector_errors: fun(erroring_func: fun()))
  local function add_selected_value_validation_test(
    linq_func_name,
    label_infix,
    selector_name,
    func,
    return_value_index
  )
    label_infix = label_infix and (" "..label_infix) or ""
    selector_name = selector_name or "selector"
    add_test(linq_func_name.." where the "..selector_name.." returns 'nil'"..label_infix.." errors", function()
      func(function(erroring_func)
        assert.errors(
          "The "..selector_name.." for '"..linq_func_name.."' must not return nil "
            ..(return_value_index and "as return value #"..return_value_index.." " or "")
            .."for any value in the sequence, but for one it did return 'nil'.",
          erroring_func
        )
      end)
    end)
  end

  add_test("creating a linq object from a table", function()
    local obj = linq(get_test_strings())
    assert_iteration(obj, get_test_strings())
  end)

  add_test("creating a linq object from a stack", function()
    local value_stack = stack.new_stack()
    for _, value in ipairs(get_test_strings()) do
      stack.push(value_stack, value)
    end
    local obj = linq(value_stack)
    assert_iteration(obj, get_test_strings())
  end)

  add_test("creating a linq object from a stack which had some values popped", function()
    local value_stack = stack.new_stack()
    for _, value in ipairs(get_test_strings()) do
      stack.push(value_stack, value)
    end
    stack.push(value_stack, "I should not be here")
    stack.pop(value_stack)
    local obj = linq(value_stack)
    assert_iteration(obj, get_test_strings())
  end)

  add_test("creating a linq object from an iterator function", function()
    local state = {some_data = true, done = false}
    local obj = linq(function(state_arg, value)
      assert.equals(state, state_arg, "state object for the iterator")
      if state.done then return end
      if value == false then state.done = true; return end
      if (value or 0) >= 5 then return false end
      return (value or 0) + 1
    end, state, 2)
    assert_iteration(obj, {3, 4, 5, false})
  end)

  add_test("attempting to create linq object from another linq object errors", function()
    local obj = linq{}
    assert.errors(
      "Attempt to create linq object from another linq object. If this is intentional, use 'copy' instead.",
      function()
        linq(obj)
      end
    )
  end)

  for _, data in ipairs{
    {value = nil},
    {value = 100},
    {value = "foo"},
    {value = false},
    -- userdata and thread are untested, but if the rest works, those will be just fine too
  }
  do
    add_test("attempting to create a linq object from a value with the type '"..type(data.value).."' errors", function()
      assert.errors("Expected table or function for 'tab_or_iter', got '"..type(data.value).."'.", function()
        linq(data.value)
      end)
    end)
  end

  add_condition_validation_test("all", false, function(condition)
    linq{}:all(condition)
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

  add_condition_validation_test("any", true, function(condition)
    linq{}:any(condition)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("any with 0 values, self has "..outer.label, function()
      local got = outer.make_obj{}:any()
      assert.equals(false, got, "result of 'any'")
    end)

    add_test("any with 4 values, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):any()
      assert.equals(true, got, "result of 'any'")
    end)

    add_test("any with 'false' as the first value values, self has "..outer.label, function()
      local got = outer.make_obj{false}:any()
      assert.equals(true, got, "result of 'any'")
    end)
  end

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

  add_collection_validation_test("append", "collection", false, function(collection)
    linq{}:append(collection)
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

  add_selector_validation_test("average", true, function(selector)
    linq{}:average(selector)
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

  add_sequence_number_validation_test("average", "using selector", true, function(selected_value, assert_errors)
    local obj = linq{"foo"}
    assert_errors(function()
      obj:average(function() return selected_value end)
    end)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_sequence_number_validation_test("average", "with "..outer.label, false, function(value, assert_errors)
      local obj = outer.make_obj{value}
      assert_errors(function()
        obj:average()
      end)
    end)
  end

  add_size_validation_test("chunk", function(size)
    linq{}:chunk(size)
  end)

  for _, data in ipairs{
    {value_count = 0, chunk_size = 1, expected = 0},
    {value_count = 2, chunk_size = 1, expected = 2},
    {value_count = 2, chunk_size = 2, expected = 1},
    {value_count = 2, chunk_size = 3, expected = 1},
  }
  do
    add_test(
      "chunk calculates the correct __count: "
        ..data.value_count.." values, chunk size "..data.chunk_size.." = "..data.expected,
      function()
        local values = {}
        for i = 1, data.value_count do
          values[i] = i
        end
        local obj = linq(values):chunk(data.chunk_size)
        local got = obj.__count
        assert.equals(data.expected, got, "internal __count after 'chunk'")
      end
    )
  end

  add_test("chunk where self has unknown __count", function()
    local obj = linq{}
    obj.__count = nil
    obj = obj:chunk(1)
    local got = obj.__count
    assert.equals(nil, got, "internal __count after 'chunk'")
  end)

  add_test("chunk where value count is zero", function()
    local obj = linq{}:chunk(1)
    assert_iteration(obj, {})
  end)

  add_test("chunk where value count is a multiple of the chunk size", function()
    local obj = linq(get_test_strings()):chunk(2)
    assert_iteration(obj, {{"foo", "bar"}, {false, "baz"}})
  end)

  add_test("chunk where value count is not a multiple of the chunk size", function()
    local obj = linq(get_test_strings()):chunk(3)
    assert_iteration(obj, {{"foo", "bar", false}, {"baz"}})
  end)

  add_search_value_validation_test("contains", function(value)
    linq{}:contains(value)
  end)

  add_test("contains with a value that exists", function()
    local got = linq(get_test_strings()):contains("bar")
    assert.equals(true, got, "result of 'contains'")
  end)

  add_test("contains with a value that does not exist", function()
    local got = linq(get_test_strings()):contains(123)
    assert.equals(false, got, "result of 'contains'")
  end)

  add_test("copy creates a new object which can be iterated separately", function()
    -- this test actually also tests that the wrapped iterator only gets iterated once, because if it didn't
    -- do that then the second assert_iteration would fail containing zero elements
    local obj = linq(get_test_strings())
    local copied = obj:copy()
    assert_iteration(obj, get_test_strings())
    assert_iteration(copied, get_test_strings())
  end)

  add_test("copy makes __count known", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    local copied = obj:copy()
    local got = obj.__count
    local got_copy = copied.__count
    assert.equals(4, got, "internal __count for original object after 'copy'")
    assert.equals(4, got_copy, "internal __count for copied object")
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

  add_default_value_validation_test("default_if_empty", function(default)
    linq{}:default_if_empty(default)
  end)

  add_test("default_if_empty leaves __count untouched when it is > 0", function()
    local obj = linq{"foo", "bar"}:default_if_empty("baz")
    local got = obj.__count
    assert.equals(2, got, "internal __count after 'default_if_empty'")
  end)

  add_test("default_if_empty sets __count to 1 when it was 0", function()
    local obj = linq{}:default_if_empty("baz")
    local got = obj.__count
    assert.equals(1, got, "internal __count after 'default_if_empty'")
  end)

  add_test("default_if_empty doesn't break with unknown __count", function()
    local obj = linq{}
    obj.__count = nil
    obj = obj:default_if_empty("baz")
    local got = obj.__count
    assert.equals(nil, got, "internal __count after 'default_if_empty'")
  end)

  add_test("default_if_empty leaves sequence untouched when it is not empty", function()
    local obj = linq{false, "foo", "bar"}:default_if_empty("baz")
    assert_iteration(obj, {false, "foo", "bar"})
  end)

  add_test("default_if_empty uses default value when sequence is empty", function()
    local obj = linq{}:default_if_empty(false)
    assert_iteration(obj, {false})
  end)

  add_test("default_if_empty uses default value getter function when sequence is empty", function()
    local obj = linq{}:default_if_empty(function() return false end)
    assert_iteration(obj, {false})
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

  add_selector_validation_test("distinct_by", false, function(selector)
    linq{}:distinct_by(selector)
  end)

  add_test("distinct_by", function()
    local obj = linq(get_test_strings())
      :distinct_by(function(value) return type(value) == "string" and value:sub(1, 2) or value end)
    ;
    assert_iteration(obj, {"foo", "bar", false})
  end)

  add_test("distinct_by using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.distinct_by, function() return 1 end)
  end)

  add_selected_value_validation_test("distinct_by", nil, nil, function(assert_selector_errors)
    local obj = linq{"foo"}:distinct_by(function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_test("ensure_knows_count does nothing if __count is known", function()
    local obj = linq(get_test_strings())
    local expected_iter = obj.__iter
    obj = obj:ensure_knows_count()
    local got_iter = obj.__iter
    local got_count = obj.__count
    assert.equals(4, got_count, "internal __count after 'ensure_knows_count'")
    assert.equals(expected_iter, got_iter, "internal __iter before and after 'ensure_knows_count'")
    assert_iteration(obj, get_test_strings())
  end)

  add_test("ensure_knows_count evaluates count if __count is unknown", function()
    local obj = linq(get_test_strings())
    obj.__count = nil
    obj = obj:ensure_knows_count()
    local got_count = obj.__count
    assert.equals(4, got_count, "internal __count after 'ensure_knows_count'")
    assert_iteration(obj, get_test_strings())
  end)

  add_index_validation_test("element_at", function(index)
    linq{}:element_at(index)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("element_at with index past the sequence, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):element_at(5)
      assert.equals(nil, got, "result of 'element_at'")
    end)

    add_test("element_at with index within the sequence, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):element_at(4)
      assert.equals("baz", got, "result of 'element_at'")
    end)
  end

  add_index_validation_test("element_at_from_end", function(index)
    linq{}:element_at_from_end(index)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("element_at_from_end with index past the sequence, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):element_at_from_end(5)
      assert.equals(nil, got, "result of 'element_at_from_end'")
    end)

    add_test("element_at_from_end with index within the sequence, self has "..outer.label, function()
      local got = outer.make_obj{"foo", "bar", "baz", "bat", "hello", "world", "hi"}:element_at_from_end(3)
      assert.equals("hello", got, "result of 'element_at_from_end'")
    end)
  end

  add_collection_validation_test("except", "collection", false, function(collection)
    linq{}:except(collection)
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

  add_collection_validation_test("except_by", "collection", false, function(collection)
    linq{}:except_by(collection, function(value) return value end)
  end)

  add_function_validation_test("except_by", "key selector", false, function(key_selector)
    linq{}:except_by({}, key_selector)
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

  add_selected_value_validation_test("except_by", nil, "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:except_by({}, function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_lut_validation_test("except_lut", function(lut)
    linq{}:except_lut(lut)
  end)

  add_test("except_lut is nearly identical to except", function()
    local got_lut = {bar = true, [false] = true}
    local expected_lut = util.shallow_copy(got_lut)
    local obj = linq(get_test_strings()):except_lut(got_lut)
    assert_iteration(obj, {"foo", "baz"})
    assert.contents_equals(expected_lut, got_lut,
      "the lookup table passed to 'except_lut' must not be modified"
    )
  end)

  add_lut_validation_test("except_lut_by", function(lut)
    linq{}:except_lut_by(lut, function(value) return value end)
  end)

  add_function_validation_test("except_lut_by", "key selector", false, function(key_selector)
    linq{}:except_lut_by({}, key_selector)
  end)

  add_test("except_lut_by is nearly identical to except_by", function()
    local got_lut = {[5] = true}
    local expected_lut = util.shallow_copy(got_lut)
    local obj = linq{"hi", "there", "friend"}:except_lut_by(got_lut, function(value) return #value end)
    assert_iteration(obj, {"hi", "friend"})
    assert.contents_equals(expected_lut, got_lut,
      "the lookup table passed to 'except_lut_by' must not be modified"
    )
  end)

  add_selected_value_validation_test("except_lut_by", nil, "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:except_lut_by({}, function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_condition_validation_test("first", true, function(condition)
    linq{}:first(condition)
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

  add_action_validation_test("for_each", false, function(action)
    linq{}:for_each(action)
  end)

  add_test("for_each with an action using index arg", function()
    local values = get_test_strings()
    local obj = linq(values)
    assert_sequential_helper(obj, obj.for_each, function(value, i)
      assert.equals(values[i], value, "value #"..i)
    end)
  end)

  add_function_validation_test("group_by", "key selector", false, function(key_selector)
    linq{}:group_by(key_selector)
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

  add_selected_value_validation_test("group_by", nil, "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:group_by(function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_function_validation_test("group_by_select", "key selector", false, function(key_selector)
    linq{}:group_by_select(key_selector, function(value) return value end)
  end)

  add_function_validation_test("group_by_select", "element selector", false, function(element_selector)
    linq{}:group_by_select(function(value) return value end, element_selector)
  end)

  add_test("group_by_select creating 2 groups", function()
    local obj = linq(get_test_strings())
      :group_by_select(
        function(value) return type(value) end,
        function(value) return type(value) == "string" and value:sub(1, 2) or value end
      )
    ;
    assert_iteration(obj, {
      {key = "string", count = 3, "fo", "ba", "ba"},
      {key = "boolean", count = 1, false},
    })
  end)

  add_test("group_by_select with both selectors using index arg", function()
    local obj = linq(get_test_strings())
      :group_by_select(
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i)
          return "key"
        end),
        assert_sequential_factory(function(assert_sequential, value, i)
          assert_sequential(value, i)
          return value
        end)
      )
    ;
    iterate(obj)
  end)

  add_test("group_by_select makes __count unknown", function()
    local obj = linq(get_test_strings())
      :group_by_select(
        function() return "key" end,
        function() return "value" end
      )
    ;
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_selected_value_validation_test("group_by_select", nil, "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:group_by_select(function() return nil end, function(value) return value end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_selected_value_validation_test("group_by_select", nil, "element selector", function(assert_selector_errors)
    local obj = linq{"foo"}:group_by_select(function(value) return value end, function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_collection_validation_test("group_join", "inner collection", false, function(inner_collection)
    linq{}:group_join(inner_collection, function(value) return value end, function(value) return value end)
  end)

  add_function_validation_test("group_join", "outer key selector", false, function(outer_key_selector)
    linq{}:group_join({}, outer_key_selector, function(value) return value end)
  end)

  add_function_validation_test("group_join", "inner key selector", false, function(inner_key_selector)
    linq{}:group_join({}, function(value) return value end, inner_key_selector)
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

  add_selected_value_validation_test("group_join", nil, "outer key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:group_join({}, function() return nil end, function(value) return value end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
    add_selected_value_validation_test(
      "group_join",
      "inner is "..inner.label,
      "inner key selector",
      function(assert_selector_errors)
        local obj = linq{}
          :group_join(inner.make_obj{"foo"}, function(value) return value end, function() return nil end)
        ;
        assert_selector_errors(function()
          iterate(obj)
        end)
      end
    )
  end

  add_search_value_validation_test("index_of", function(value)
    linq{}:index_of(value)
  end)

  add_test("index_of where the value exists in the sequence", function()
    local got = linq(get_test_strings()):index_of(false)
    assert.equals(3, got, "result of 'index_of'")
  end)

  add_test("index_of finds the first value in the sequence", function()
    local got = linq{"foo", "bar", "baz", "bar", "bat"}:index_of("bar")
    assert.equals(2, got, "result of 'index_of'")
  end)

  add_test("index_of where the value does not exist in the sequence", function()
    local got = linq(get_test_strings()):index_of("hello")
    assert.equals(nil, got, "result of 'index_of'")
  end)

  add_search_value_validation_test("index_of_last", function(value)
    linq{}:index_of_last(value)
  end)

  add_test("index_of_last where the value exists in the sequence", function()
    local got = linq(get_test_strings()):index_of_last(false)
    assert.equals(3, got, "result of 'index_of'")
  end)

  add_test("index_of_last finds the last value in the sequence", function()
    local got = linq{"foo", "bar", "baz", "bar", "bat"}:index_of_last("bar")
    assert.equals(4, got, "result of 'index_of'")
  end)

  add_test("index_of_last where the value does not exist in the sequence", function()
    local got = linq(get_test_strings()):index_of_last("hello")
    assert.equals(nil, got, "result of 'index_of'")
  end)

  add_index_validation_test("index", function(index)
    linq{}:insert(index, "foo")
  end)

  add_insert_value_validation_test("index", function(value)
    linq{}:insert(1, value)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {label = "at the front", index = 1, expected = {"inserted", "foo", "bar", false, "baz"}},
      {label = "in the middle", index = 3, expected = {"foo", "bar", "inserted", false, "baz"}},
      {label = "right at the end", index = 5, expected = {"foo", "bar", false, "baz", "inserted"}},
      {label = "past the end", index = 6, expected = {"foo", "bar", false, "baz", "inserted"}},
      {label = "further past the end", index = 7, expected = {"foo", "bar", false, "baz", "inserted"}},
    }
    do
      add_test("insert "..data.label.." (count = 4, index = "..data.index.."), self with "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):insert(data.index, "inserted")
        local got_count = obj.__count
        assert.equals(outer.knows_count and 5 or nil, got_count, "internal __count after 'insert'")
        assert_iteration(obj, data.expected)
      end)
    end
  end

  add_index_validation_test("insert_range", function(index)
    linq{}:insert_range(index, {})
  end)

  add_collection_validation_test("insert_range", "collection", false, function(collection)
    linq{}:insert_range(1, collection)
  end)

  -- insert_range
  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
      for _, data in ipairs{
        {
          label = "at the front",
          index = 1,
          values = {"hello", false, "world"},
          expected = {"hello", false, "world", "foo", "bar", false, "baz"},
        },
        {
          label = "in the middle",
          index = 3,
          values = {"hello", false, "world"},
          expected = {"foo", "bar", "hello", false, "world", false, "baz"},
        },
        {
          label = "right at the end",
          index = 5,
          values = {"hello", false, "world"},
          expected = {"foo", "bar", false, "baz", "hello", false, "world"},
        },
        {
          label = "past the end",
          index = 6,
          values = {"hello", false, "world"},
          expected = {"foo", "bar", false, "baz", "hello", false, "world"},
        },
        {
          label = "further past the end",
          index = 7,
          values = {"hello", false, "world"},
          expected = {"foo", "bar", false, "baz", "hello", false, "world"},
        },
      }
      do
        add_test("insert_range "..inner.label.." "..data.label
            .." (outer count = 4, index = "..data.index.."), self with "..outer.label,
          function()
            local inner_collection = inner.make_obj(data.values)
            local obj = outer.make_obj(get_test_strings()):insert_range(data.index, inner_collection)
            local expected_count = (outer.knows_count and inner.knows_count) and (4 + #data.values) or nil
            local got_count = obj.__count
            assert.equals(expected_count, got_count, "internal __count after 'insert_range'")
            assert_iteration(obj, data.expected)
          end
        )
      end
    end
  end

  add_collection_validation_test("intersect", "collection", false, function(collection)
    linq{}:intersect(collection)
  end)

  add_lut_validation_test("intersect_lut", function(lut)
    linq{}:intersect_lut(lut)
  end)

  -- intersect
  for _, data in ipairs{
    {
      label = "strings and 'false'",
      outer = get_test_strings(),
      inner = get_test_strings(),
      expected = get_test_strings(),
    },
    {
      label = "empty collections",
      outer = {},
      inner = {},
      expected = {},
    },
    {
      label = "outer has 2, inner has 2, 1 intersection",
      outer = {"hello", "world"},
      inner = {"goodbye", "world"},
      expected = {"world"},
    },
    {
      label = "outer's value duplicated, distinct in result",
      outer = {"world", "hello", "world"},
      inner = {"goodbye", "world"},
      expected = {"world"},
    },
    {
      label = "inner's value duplicated, distinct in result",
      outer = {"hello", "world"},
      inner = {"world", "goodbye", "world"},
      expected = {"world"},
    },
  }
  do
    for _, outer in ipairs(known_or_unknown_count_dataset) do
      for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
        add_test("intersect with "..data.label.." with "..inner.label..", self has "..outer.label, function()
          local obj = outer.make_obj(data.outer):intersect(inner.make_obj(data.inner))
          assert_iteration(obj, data.expected)
        end)
      end

      add_test("intersect_lut with "..data.label..", self has "..outer.label, function()
        local got_lut = util.invert(data.inner)
        local expected_lut = util.shallow_copy(got_lut)
        local obj = outer.make_obj(data.outer):intersect_lut(util.invert(data.inner))
        assert_iteration(obj, data.expected)
        assert.contents_equals(expected_lut, got_lut,
          "the lookup table passed to 'intersect_lut' must not be modified"
        )
      end)
    end
  end

  add_test("intersect makes __count unknown", function()
    local obj = linq{}:intersect{}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("intersect_lut makes __count unknown", function()
    local obj = linq{}:intersect_lut{}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_collection_validation_test("intersect_by", "key collection", false, function(key_collection)
    linq{}:intersect_by(key_collection, function(value) return value end)
  end)

  add_function_validation_test("intersect_by", "key selector", false, function(key_selector)
    linq{}:intersect_by({}, key_selector)
  end)

  add_lut_validation_test("intersect_lut_by", function(lut)
    linq{}:intersect_lut_by(lut, function(value) return value end)
  end)

  add_function_validation_test("intersect_lut_by", "key selector", false, function(key_selector)
    linq{}:intersect_lut_by({}, key_selector)
  end)

  -- intersect_by
  for _, data in ipairs{
    {
      label = "strings and 'false'",
      outer = get_test_strings(),
      inner = {"o", "r", false, "z"},
      key_selector = function(value)
        return type(value) == "string" and value:sub(3, 3) or value
      end,
      expected = get_test_strings(),
    },
    {
      label = "empty collections",
      outer = {},
      inner = {},
      key_selector = function(value) return value end,
      expected = {},
    },
    {
      label = "outer has 2, inner has 2, 1 intersection",
      outer = {"hello", "world"},
      inner = {"goo", "wor"},
      key_selector = function(value) return value:sub(1, 3) end,
      expected = {"world"},
    },
    {
      label = "outer's value duplicated, distinct in result",
      outer = {"world", "hello", "world"},
      inner = {"goo", "wor"},
      key_selector = function(value) return value:sub(1, 3) end,
      expected = {"world"},
    },
    {
      label = "inner's value duplicated, distinct in result",
      outer = {"hello", "world"},
      inner = {"wor", "goo", "wor"},
      key_selector = function(value) return value:sub(1, 3) end,
      expected = {"world"},
    },
  }
  do
    for _, outer in ipairs(known_or_unknown_count_dataset) do
      for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
        add_test("intersect_by with "..data.label.." with "..inner.label..", self has "..outer.label, function()
          local obj = outer.make_obj(data.outer):intersect_by(inner.make_obj(data.inner), data.key_selector)
          assert_iteration(obj, data.expected)
        end)
      end

      add_test("intersect_lut_by with "..data.label..", self has "..outer.label, function()
        local got_lut = util.invert(data.inner)
        local expected_lut = util.shallow_copy(got_lut)
        local obj = outer.make_obj(data.outer):intersect_lut_by(got_lut, data.key_selector)
        assert_iteration(obj, data.expected)
        assert.contents_equals(expected_lut, got_lut,
          "the lookup table passed to 'intersect_lut_by' must not be modified"
        )
      end)
    end
  end

  add_test("intersect_by makes __count unknown", function()
    local obj = linq{}:intersect_by({}, function(value) return value end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("intersect_by with key_selector using index arg", function()
    local obj = linq(get_test_strings())
      :intersect_by(linq{"fo", "ba"}, assert_sequential_factory(function(assert_sequential, value, i)
        assert_sequential(value, i)
        return value:sub(1, 2)
      end))
    ;
  end)

  add_selected_value_validation_test("intersect_by", nil, "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:intersect_by({}, function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_test("intersect_lut_by makes __count unknown", function()
    local obj = linq{}:intersect_lut_by({}, function(value) return value end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("iterate returns the correct iterator", function()
    local obj = linq{}
    local got_iter = obj:iterate()
    assert.equals(obj.__iter, got_iter, "iterator")
  end)

  add_collection_validation_test("join", "inner collection", false, function(inner_collection)
    local function selector(value) return value end
    linq{}:join(inner_collection, selector, selector, selector)
  end)

  add_function_validation_test("join", "outer key selector", false, function(outer_key_selector)
    local function selector(value) return value end
    linq{}:join({}, outer_key_selector, selector, selector)
  end)

  add_function_validation_test("join", "inner key selector", false, function(inner_key_selector)
    local function selector(value) return value end
    linq{}:join({}, selector, inner_key_selector, selector)
  end)

  add_function_validation_test("join", "result selector", false, function(result_selector)
    local function selector(value) return value end
    linq{}:join({}, selector, selector, result_selector)
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

  add_selected_value_validation_test("join", nil, "outer key selector", function(assert_selector_errors)
    local obj = linq{"foo"}
      :join(
        {"bar"},
        function() return nil end,
        function(value) return value end,
        function(value) return value end
      )
    ;
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_selected_value_validation_test("join", nil, "inner key selector", function(assert_selector_errors)
    local obj = linq{"foo"}
      :join(
        {"bar"},
        function(value) return value end,
        function() return (nil)--[[@as string]] end,
        function(value) return value end
      )
    ;
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_selected_value_validation_test("join", nil, "result selector", function(assert_selector_errors)
    local obj = linq{"bar"}
      :join(
        {"baz"},
        function(value) return value:sub(1, 1) end,
        function(value) return value:sub(1, 1) end,
        function() return nil end
      )
    ;
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_index_validation_test("keep_at", function(index)
    linq{}:keep_at(index)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {index = 1, expected_count = 1, expected_results = {"foo"}},
      {index = 2, expected_count = 1, expected_results = {"bar"}},
      {index = 3, expected_count = 1, expected_results = {false}},
      {index = 4, expected_count = 1, expected_results = {"baz"}},
      {index = 5, expected_count = 0, expected_results = {}},
      {index = 6, expected_count = 0, expected_results = {}},
    }
    do
      add_test("keep_at index "..data.index.." out of 4, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):keep_at(data.index)
        local expected_count = outer.knows_count and data.expected_count or nil
        local got_count = obj.__count
        assert.equals(expected_count, got_count, "internal __count after 'keep_at'")
        assert_iteration(obj, data.expected_results)
      end)
    end
  end

  add_index_validation_test("keep_range", function(start_index)
    linq{}:keep_range(start_index, 1)
  end, "start index")

  add_index_validation_test("keep_range", function(stop_index)
    linq{}:keep_range(1, stop_index)
  end, "stop index")

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {start = 1, stop = 1, expected_count = 1, expected_results = {"foo"}},
      {start = 2, stop = 2, expected_count = 1, expected_results = {"bar"}},
      {start = 1, stop = 3, expected_count = 3, expected_results = {"foo", "bar", false}},
      {start = 2, stop = 4, expected_count = 3, expected_results = {"bar", false, "baz"}},
      {start = 3, stop = 5, expected_count = 2, expected_results = {false, "baz"}},
      {start = 4, stop = 6, expected_count = 1, expected_results = {"baz"}},
      {start = 5, stop = 7, expected_count = 0, expected_results = {}},
      {start = 2, stop = 1, expected_count = 0, expected_results = {}},
      -- with pure math this could result in -1 __count, this test ensures it's 0 instead
      {start = 3, stop = 1, expected_count = 0, expected_results = {}},
    }
    do
      add_test("keep_range from "..data.start.." to "..data.stop.." out of 4, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):keep_range(data.start, data.stop)
        local expected_count = outer.knows_count and data.expected_count or nil
        local got_count = obj.__count
        assert.equals(expected_count, got_count, "internal __count after 'keep_range'")
        assert_iteration(obj, data.expected_results)
      end)
    end
  end

  add_condition_validation_test("last", true, function(condition)
    linq{}:last(condition)
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

  add_comparator_validation_test("max", true, function(comparator)
    linq{1}:max(comparator)
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
    assert.errors("Attempt to evaluate max value on an empty collection.", function()
      obj:max()
    end)
  end)

  add_sequence_number_validation_test("max", "as the first value", false, function(value, assert_errors)
    local obj = linq{value, 1}
    assert_errors(function()
      obj:max()
    end)
  end)

  add_sequence_number_validation_test("max", "as the second value", false, function(value, assert_errors)
    local obj = linq{1, value}
    assert_errors(function()
      obj:max()
    end)
  end)

  add_selector_validation_test("max_by", false, function(selector)
    linq{1}:max_by(selector)
  end)

  add_comparator_validation_test("max_by", true, function(comparator)
    linq{1}:max_by(function(value) return value end, comparator)
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
    assert.errors("Attempt to evaluate max value on an empty collection.", function()
      obj:max_by(function(value) return value end)
    end)
  end)

  add_test("max_by with selector using index arg", function()
    linq{1, 4, 2, 3, 10}:max_by(assert_sequential_factory(function(assert_sequential, value, i)
      assert_sequential(value, i)
      return value
    end))
  end)

  add_sequence_number_validation_test("max_by", "as the first value", true, function(value, assert_errors)
    local obj = linq{1, 1}
    assert_errors(function()
      obj:max_by(function(_, i) if i == 1 then return value else return 1 end end)
    end)
  end)

  add_sequence_number_validation_test("max_by", "as the second value", true, function(value, assert_errors)
    local obj = linq{1, 1}
    assert_errors(function()
      obj:max_by(function(_, i) if i == 2 then return value else return 1 end end)
    end)
  end)

  add_comparator_validation_test("min", true, function(comparator)
    linq{1}:min(comparator)
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
    assert.errors("Attempt to evaluate min value on an empty collection.", function()
      obj:min()
    end)
  end)

  add_sequence_number_validation_test("min", "as the first value", false, function(value, assert_errors)
    local obj = linq{value, 1}
    assert_errors(function()
      obj:min()
    end)
  end)

  add_sequence_number_validation_test("min", "as the second value", false, function(value, assert_errors)
    local obj = linq{1, value}
    assert_errors(function()
      obj:min()
    end)
  end)

  add_selector_validation_test("min_by", false, function(selector)
    linq{1}:min_by(selector)
  end)

  add_comparator_validation_test("min_by", true, function(comparator)
    linq{1}:min_by(function(value) return value end, comparator)
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
    assert.errors("Attempt to evaluate min value on an empty collection.", function()
      obj:min_by(function(value) return value end)
    end)
  end)

  add_test("min_by with selector using index arg", function()
    linq{1, 4, 2, 3, 10}:min_by(assert_sequential_factory(function(assert_sequential, value, i)
      assert_sequential(value, i)
      return value
    end))
  end)

  add_sequence_number_validation_test("min_by", "as the first value", true, function(value, assert_errors)
    local obj = linq{1, 1}
    assert_errors(function()
      obj:min_by(function(_, i) if i == 1 then return value else return 1 end end)
    end)
  end)

  add_sequence_number_validation_test("min_by", "as the second value", true, function(value, assert_errors)
    local obj = linq{1, 1}
    assert_errors(function()
      obj:min_by(function(_, i) if i == 2 then return value else return 1 end end)
    end)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {label = "no values", values = {}, expected = {}},
      {label = "one value", values = {1}, expected = {1}},
      {label = "three values", values = {2, 8, 4}, expected = {2, 4, 8}},
      {label = "duplicate values", values = {2, 8, 2, 8, 2, 4}, expected = {2, 2, 2, 4, 8, 8}},
      {label = "five values", values = {4, 2, 10, 6, 8}, expected = {2, 4, 6, 8, 10}},
    }
    do
      add_test("order with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values):order()
        assert_iteration(obj, data.expected)
      end)

      local reverse_expected = {}
      local count = #data.expected
      for i = 1, count do
        reverse_expected[count - i + 1] = data.expected[i]
      end
      add_test("order_descending with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values):order_descending()
        assert_iteration(obj, reverse_expected)
      end)
    end
  end

  add_selector_validation_test("order_by", false, function(selector)
    linq{}:order_by(selector)
  end)

  add_selector_validation_test("order_descending_by", false, function(selector)
    linq{}:order_descending_by(selector)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    -- ordered starting at the second character instead of first
    for _, data in ipairs{
      {label = "no values", values = {}, expected = {}},
      {label = "one value", values = {"hello"}, expected = {"hello"}},
      {label = "three values", values = {"foo", "bar", "baz"}, expected = {"bar", "baz", "foo"}},
      {
        label = "duplicate values",
        values = {"foo", "bar", "foo", "baz", "baz", "foo"},
        expected = {"bar", "baz", "baz", "foo", "foo", "foo"},
      },
      {
        label = "five values",
        values = {"hello", "world", "foo", "baz", "bar"},
        expected = {"bar", "baz", "hello", "foo", "world"},
      },
    }
    do
      add_test("order_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values):order_by(function(value) return value:sub(2, -1) end)
        assert_iteration(obj, data.expected)
      end)

      add_test("order_descending_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values):order_descending_by(function(value) return value:sub(2, -1) end)
        assert_iteration(obj, reverse_array(data.expected))
      end)
    end
  end

  add_collection_validation_test("prepend", "collection", false, function(collection)
    linq{}:prepend(collection)
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

  add_index_validation_test("remove_at", function(index)
    linq{}:remove_at(index)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {label = "first value", index = 1, expected_count = 3, expected_results = {"bar", false, "baz"}},
      {label = "middle value", index = 3, expected_count = 3, expected_results = {"foo", "bar", "baz"}},
      {label = "last value", index = 4, expected_count = 3, expected_results = {"foo", "bar", false}},
      {label = "past end", index = 5, expected_count = 4, expected_results = get_test_strings()},
      {label = "further past end", index = 6, expected_count = 4, expected_results = get_test_strings()},
    }
    do
      add_test("remove_at index "..data.index.." out of 4 ("..data.label.."), self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):remove_at(data.index)
        local expected_count = outer.knows_count and data.expected_count or nil
        local got_count = obj.__count
        assert.equals(expected_count, got_count, "internal __count after 'remove_at'")
        assert_iteration(obj, data.expected_results)
      end)
    end
  end

  add_index_validation_test("remove_range", function(start_index)
    linq{}:remove_range(start_index, 1)
  end, "start index")

  add_index_validation_test("remove_range", function(stop_index)
    linq{}:remove_range(1, stop_index)
  end, "stop index")

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      -- this dataset is similar to the one for keep_range
      {start = 1, stop = 1, expected_count = 3, expected_results = {"bar", false, "baz"}},
      {start = 2, stop = 2, expected_count = 3, expected_results = {"foo", false, "baz"}},
      {start = 1, stop = 3, expected_count = 1, expected_results = {"baz"}},
      {start = 2, stop = 4, expected_count = 1, expected_results = {"foo"}},
      {start = 3, stop = 5, expected_count = 2, expected_results = {"foo", "bar"}},
      {start = 4, stop = 6, expected_count = 3, expected_results = {"foo", "bar", false}},
      {start = 5, stop = 7, expected_count = 4, expected_results = get_test_strings()},
      {start = 2, stop = 1, expected_count = 4, expected_results = get_test_strings()},
      -- with pure math this could result in 5 __count, this test ensures it's 4 instead
      {start = 3, stop = 1, expected_count = 4, expected_results = get_test_strings()},
    }
    do
      add_test("remove_range from "..data.start.." to "..data.stop.." out of 4, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):remove_range(data.start, data.stop)
        local expected_count = outer.knows_count and data.expected_count or nil
        local got_count = obj.__count
        assert.equals(expected_count, got_count, "internal __count after 'remove_range'")
        assert_iteration(obj, data.expected_results)
      end)
    end
  end

  add_test("reverse with 0 values", function()
    local obj = linq{}:reverse()
    assert_iteration(obj, {})
  end)

  add_test("reverse with 4 values", function()
    local obj = linq(get_test_strings()):reverse()
    assert_iteration(obj, {"baz", false, "bar", "foo"})
  end)

  add_selector_validation_test("select", false, function(selector)
    linq{}:select(selector)
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

  add_selected_value_validation_test("select", nil, nil, function(assert_selector_errors)
    local obj = linq{"foo"}:select(function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  add_selector_validation_test("select_many", false, function(selector)
    linq{}:select_many(selector)
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

  -- NOTE: these selected collection tests break the rule described in the IMPORTANT tag at the top
  for _, data in ipairs{1, 2} do
    add_collection_validation_test("select_many", "selected collection #"..data, false, function(collection)
      local obj = linq{{"foo"}, {"bar"}}
        :select_many(function(v, i)
          if i == data then
            return collection
          else
            return v
          end
        end)
      ;
      iterate(obj)
    end)
  end

  add_collection_validation_test("sequence_equal", "collection", false, function(collection)
    linq{}:sequence_equal(collection)
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

  add_condition_validation_test("single", true, function(condition)
    linq{"foo"}:single(condition)
  end)

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
          assert.errors(err_msg_prefix..data.error..".", function()
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
          "Expected a single value in the sequence to match the condition, got "..data.error..".",
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

  add_count_validation_test("skip", function(count)
    linq{}:skip(count)
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

  add_count_validation_test("skip_last", function(count)
    linq{}:skip_last(count)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {skip_count = 0, expected_count = 4, expected = get_test_strings()},
      {skip_count = 1, expected_count = 3, expected = {"foo", "bar", false}},
      {skip_count = 3, expected_count = 1, expected = {"foo"}},
      {skip_count = 4, expected_count = 0, expected = {}},
      {skip_count = 5, expected_count = 0, expected = {}},
    }
    do
      add_test("skip_last "..data.skip_count.." out of 4 values, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):skip_last(data.skip_count)
        local expected_count = outer.knows_count and data.expected_count or nil
        assert.equals(expected_count, obj.__count, "internal __count after skip")
        assert_iteration(obj, data.expected)
      end)
    end
  end

  add_condition_validation_test("skip_last_while", false, function(condition)
    linq{}:skip_last_while(condition)
  end)

  for _, data in ipairs{
    {skip_count = 0, expected = get_test_strings(), condition = function(value) return false end},
    {skip_count = 1, expected = {"foo", "bar", false}, condition = function(value) return value == "baz" end},
    {skip_count = 3, expected = {"foo"}, condition = function(value) return value ~= "foo" end},
    {skip_count = 4, expected = {}, condition = function(value) return true end},
  }
  do
    add_test("skip_last_while "..data.skip_count.." out of 4 values", function()
      local obj = linq(get_test_strings()):skip_last_while(data.condition)
      assert_iteration(obj, data.expected)
    end)
  end

  add_test("skip_last_while with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.skip_last_while, function() return true end, 4, -1)
  end)

  add_test("skip_last_while makes __count unknown", function()
    local obj = linq(get_test_strings()):skip_last_while(function() return true end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_condition_validation_test("skip_while", false, function(condition)
    linq{}:skip_while(condition)
  end)

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

  add_comparator_validation_test("sort", false, function(comparator)
    linq{}:sort(comparator)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("sort, self has "..outer.label, function()
      local obj = outer.make_obj(get_test_strings()):sort(function(left, right)
        if type(left) == "boolean" then
          return true
        end
        if type(right) == "boolean" then
          return false
        end
        return left < right
      end)
      assert_iteration(obj, {false, "bar", "baz", "foo"})
    end)
  end

  add_selector_validation_test("sum", true, function(selector)
    linq{}:sum(selector)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    local function selector(value)
      return type(value) == "string" and #value or 5
    end
    for _, data in ipairs{
      {label = "of 0 values", values = {}, expected = 0},
      {label = "of 1 value", values = {100}, expected = 100},
      {label = "of 2 values", values = {100, 20}, expected = 120},
      {label = "of 3 values", values = {100, 20, 3}, expected = 123},
      {label = "of 0 values using selector", values = {}, selector = selector, expected = 0},
      {label = "of 1 value using selector", values = {"f"}, selector = selector, expected = 1},
      {label = "of 2 values using selector", values = {"f", "oo"}, selector = selector, expected = 3},
      {label = "of 4 values using selector", values = get_test_strings(), selector = selector, expected = 14},
    }
    do
      add_test("sum "..data.label..", self has "..outer.label, function()
        local got = outer.make_obj(data.values):sum(data.selector)
        assert.equals(data.expected, got, "result of 'sum'")
      end)
    end

    add_test("sum with selector using index arg, self has "..outer.label, function()
      local obj = outer.make_obj(get_test_strings())
      assert_sequential_helper(obj, obj.sum, function(_, i) return i end)
    end)
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_sequence_number_validation_test("sum", "using selector and has "..outer.label, true, function(value, assert_errors)
      local obj = outer.make_obj{"foo"}
      assert_errors(function()
        obj:sum(function() return value end)
      end)
    end)
  end

  add_sequence_number_validation_test("sum", nil, false, function(value, assert_errors)
    local obj = linq{value}
    assert_errors(function()
      obj:sum()
    end)
  end)

  add_collection_validation_test("symmetric_difference", "collection", false, function(collection)
    linq{}:symmetric_difference(collection)
  end)

  add_collection_validation_test("symmetric_difference_by", "collection", false, function(collection)
    linq{}:symmetric_difference_by(collection, function(value) return value end)
  end)

  add_function_validation_test("symmetric_difference_by", "key selector", false, function(key_selector)
    linq{}:symmetric_difference_by({}, key_selector)
  end)

  for _, data in ipairs{
    {
      label = "empty collections",
      outer_values = {},
      inner_values = {},
      expected = {},
    },
    {
      label = "all unique values",
      outer_values = get_test_strings(),
      inner_values = {"hello", "world"},
      expected = {"foo", "bar", false, "baz", "hello", "world"},
    },
    {
      label = "one duplicate between collections",
      outer_values = {"foo", "bar"},
      inner_values = {"hello", "bar", "world"},
      expected = {"foo", "hello", "world"},
    },
    {
      label = "all duplicate values",
      outer_values = get_test_strings(),
      inner_values = get_test_strings(),
      expected = {},
    },
    {
      label = "one duplicate within each same collection",
      outer_values = {"foo", "bar", "bar"},
      inner_values = {"hello", "hello", "world"},
      expected = {"foo", "bar", "hello", "world"},
    },
    {
      label = "duplicates everywhere",
      outer_values = {"foo", "bar", "bar"},
      inner_values = {"hello", "world", "foo", "bar", "bar"},
      expected = {"hello", "world"},
    },
    {
      label = "duplicates everywhere with key_selector",
      outer_values = {"foo", "bar", "baz"},
      inner_values = {"hello", "world", "for", "big", "bat"},
      key_selector = function(value) return value:sub(1, 1) end,
      expected = {"hello", "world"},
    },
  }
  do
    for _, outer in ipairs(known_or_unknown_count_dataset) do
      for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
        local func_name = data.key_selector and "symmetric_difference_by" or "symmetric_difference"
        add_test(func_name.." "..data.label.." with "..inner.label..", self has "..outer.label, function()
          local collection = inner.make_obj(data.inner_values)
          local obj = outer.make_obj(data.outer_values)
          if data.key_selector then
            obj = obj:symmetric_difference_by(collection, data.key_selector)
          else
            obj = obj:symmetric_difference(collection)
          end
          local got_count = obj.__count
          assert.equals(nil, got_count, "internal __count after '"..func_name.."'")
          assert_iteration(obj, data.expected)
        end)
      end
    end
  end

  add_test("symmetric_difference makes __count unknown", function()
    local obj = linq(get_test_strings()):symmetric_difference{"hello", "world"}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("symmetric_difference_by makes __count unknown", function()
    local obj = linq(get_test_strings())
      :symmetric_difference_by({"hello", "world"}, function(value) return value end)
    ;
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_selected_value_validation_test(
    "symmetric_difference_by",
    "in outer",
    "key selector",
    function(assert_selector_errors)
      local obj = linq{"foo"}:symmetric_difference_by({}, function() return nil end)
      assert_selector_errors(function()
        iterate(obj)
      end)
    end
  )

  for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
    add_selected_value_validation_test(
      "symmetric_difference_by",
      "in inner, inner is "..inner.label,
      "key selector",
      function(assert_selector_errors)
        local obj = linq{}:symmetric_difference_by(inner.make_obj{"foo"}, function() return nil end)
        assert_selector_errors(function()
          iterate(obj)
        end)
      end
    )
  end

  add_count_validation_test("take", function(count)
    linq{}:take(count)
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

  add_count_validation_test("take_last", function(count)
    linq{}:take_last(count)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {take_count = 0, expected_count = 0, makes_count_known = true, expected = {}},
      {take_count = 1, expected_count = 1, expected = {"baz"}},
      {take_count = 2, expected_count = 2, expected = {false, "baz"}},
      {take_count = 3, expected_count = 3, expected = {"bar", false, "baz"}},
      {take_count = 4, expected_count = 4, expected = get_test_strings()},
      {take_count = 5, expected_count = 4, expected = get_test_strings()},
    }
    do
      add_test("take_last "..data.take_count.." out of 4 values, self has "..outer.label, function()
        local obj = outer.make_obj(get_test_strings()):take_last(data.take_count)
        local expected_count = (outer.knows_count or data.makes_count_known) and data.expected_count or nil
        assert.equals(expected_count, obj.__count, "internal __count after 'take_last'")
        assert_iteration(obj, data.expected)
      end)
    end
  end

  add_condition_validation_test("take_last_while", false, function(condition)
    linq{}:take_last_while(condition)
  end)

  for _, data in ipairs{
    {take_count = 0, expected = {}, condition = function(value) return false end},
    {take_count = 1, expected = {"baz"}, condition = function(value) return value == "baz" end},
    {take_count = 3, expected = {"bar", false, "baz"}, condition = function(value) return value ~= "foo" end},
    {take_count = 4, expected = get_test_strings(), condition = function(value) return true end},
  }
  do
    add_test("take_last_while keeps "..data.take_count.." out of 4 values", function()
      local obj = linq(get_test_strings()):take_last_while(data.condition)
      assert_iteration(obj, data.expected)
    end)
  end

  add_test("take_last_while makes __count unknown", function()
    local obj = linq(get_test_strings()):take_last_while(function() return true end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("take_last_while with condition using index arg", function()
    local obj = linq(get_test_strings())
    assert_sequential_helper(obj, obj.take_last_while, function() return true end, 4, -1)
  end)

  add_condition_validation_test("take_while", false, function(condition)
    linq{}:take_while(condition)
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

  add_selector_validation_test("then_by", false, function(selector)
    linq{}:order():then_by(selector)
  end)

  add_selector_validation_test("then_descending_by", false, function(selector)
    linq{}:order():then_descending_by(selector)
  end)

  -- then_by and then_descending_by
  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {
        label = "0 values",
        values = {},
        expected = {},
        alt_expected = nil, -- the same as 'expected'
      },
      {
        label = "1 value",
        values = {{first = "hello", second = "world"}},
        expected = {{first = "hello", second = "world"}},
        alt_expected = nil, -- the same as 'expected'
      },
      {
        label = "2 values, non equal 'first' and 'second'",
        values = {
          {first = "bb", second = "cc"},
          {first = "aa", second = "dd"},
        },
        expected = {
          {first = "aa", second = "dd"},
          {first = "bb", second = "cc"},
        },
        alt_expected = nil, -- the same as 'expected'
      },
      {
        label = "2 values, non equal 'first', equal 'second'",
        values = {
          {first = "bb", second = "cc"},
          {first = "aa", second = "cc"},
        },
        expected = {
          {first = "aa", second = "cc"},
          {first = "bb", second = "cc"},
        },
        alt_expected = nil, -- the same as 'expected'
      },
      {
        label = "2 values, equal 'first', non equal 'second'",
        values = {
          {first = "aa", second = "dd"},
          {first = "aa", second = "cc"},
        },
        expected = {
          {first = "aa", second = "cc"},
          {first = "aa", second = "dd"},
        },
        alt_expected = {
          {first = "aa", second = "dd"},
          {first = "aa", second = "cc"},
        },
      },
      {
        label = "4 values, 2 middle have equal 'first' and 'second'",
        values = {
          {first = "bb", second = "ee"},
          {first = "cc", second = "dd"},
          {first = "bb", second = "ee"},
          {first = "aa", second = "ff"},
        },
        expected = {
          {first = "aa", second = "ff"},
          {first = "bb", second = "ee"},
          {first = "bb", second = "ee"},
          {first = "cc", second = "dd"},
        },
        alt_expected = nil, -- the same as 'expected'
      },
      {
        label = "6 values, 3 'first' equal, all different 'second'",
        values = {
          {first = "foo", second = "ooo"},
          {first = "bar", second = "aaa"},
          {first = "hello", second = "baz"},
          {first = "world", second = "hello"},
          {first = "hello", second = "foo"},
          {first = "hello", second = "bar"},
        },
        expected = {
          {first = "bar", second = "aaa"},
          {first = "foo", second = "ooo"},
          {first = "hello", second = "bar"},
          {first = "hello", second = "baz"},
          {first = "hello", second = "foo"},
          {first = "world", second = "hello"},
        },
        alt_expected = {
          {first = "bar", second = "aaa"},
          {first = "foo", second = "ooo"},
          {first = "hello", second = "foo"},
          {first = "hello", second = "baz"},
          {first = "hello", second = "bar"},
          {first = "world", second = "hello"},
        },
      },
    }
    do
      add_test("order_by + then_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values)
          :order_by(function(value) return value.first end)
          :then_by(function(value) return value.second end)
        ;
        assert_iteration(obj, data.expected)
      end)

      add_test("order_by + then_descending_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values)
          :order_by(function(value) return value.first end)
          :then_descending_by(function(value) return value.second end)
        ;
        -- 'alt_expected' is omitted in the definition if it's the same as 'expected'
        assert_iteration(obj, data.alt_expected or data.expected)
      end)

      -- put it a local for reuse, because why not
      local reverse_expected = reverse_array(data.expected)
      add_test("order_descending_by + then_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values)
          :order_descending_by(function(value) return value.first end)
          :then_by(function(value) return value.second end)
        ;
        -- 'alt_expected' is omitted in the definition if it's the same as 'expected'
        assert_iteration(obj, data.alt_expected and reverse_array(data.alt_expected) or reverse_expected)
      end)

      add_test("order_descending_by + then_descending_by with "..data.label..", self has "..outer.label, function()
        local obj = outer.make_obj(data.values)
          :order_descending_by(function(value) return value.first end)
          :then_descending_by(function(value) return value.second end)
        ;
        assert_iteration(obj, reverse_expected)
      end)
    end
  end

  add_test("order + then_by while it does not make sense, it works", function()
    local obj = linq{"foo", "bar", "bar"}:order():then_by(function(value) return value end)
    assert_iteration(obj, {"bar", "bar", "foo"})
  end)

  add_test("order_by + then_by + then_descending_by", function()
    local obj = linq{
      "beg",
      "aeg",
      "adg",
      "beh",
      "adh",
      "aeh",
      "bdh",
      "bdg",
    }
      :order_by(function(value) return value:sub(1, 1) end)
      :then_by(function(value) return value:sub(2, 2) end)
      :then_descending_by(function(value) return value:sub(3, 3) end)
    ;
    assert_iteration(obj, {
      "adh",
      "adg",
      "aeh",
      "aeg",
      "bdh",
      "bdg",
      "beh",
      "beg",
    })
  end)

  add_test("then_by without previous order call errors", function()
    local obj = linq{}
    assert.errors(
      "'then_by' and 'then_descending_by' must only be used directly after any of the \z
        'order' functions, or another 'then' function.",
      function()
        obj:then_by(function(value) return value end)
      end
    )
  end)

  add_test("then_descending_by without previous order call errors", function()
    local obj = linq{}
    assert.errors(
      "'then_by' and 'then_descending_by' must only be used directly after any of the \z
        'order' functions, or another 'then' function.",
      function()
        obj:then_descending_by(function(value) return value end)
      end
    )
  end)

  add_sequence_value_for_ordering_validation_test(
    "order",
    "as the first value",
    1,
    false,
    function(value, assert_errors)
      local obj = linq{value, "foo"}:order()
      assert_errors(function()
        iterate(obj)
      end)
    end
  )

  add_sequence_value_for_ordering_validation_test(
    "order",
    "as the second value",
    1,
    false,
    function(value, assert_errors)
      local obj = linq{"foo", value}:order()
      assert_errors(function()
        iterate(obj)
      end)
    end
  )

  for _, data in ipairs{{label = "first", value = "foo"}, {label = "second", value = "bar"}} do
    add_sequence_value_for_ordering_validation_test(
      "order_by",
      "as the "..data.value.." value",
      1,
      true,
      function(value, assert_errors)
        local obj =linq{"foo", "bar"}
          :order_by(function(v) if v == data.value then return value else return v end end)
        ;
        assert_errors(function()
          iterate(obj)
        end)
      end
    )
  end

  for _, data in ipairs{{label = "first", value = "foo"}, {label = "second", value = "bar"}} do
    add_sequence_value_for_ordering_validation_test(
      "order_by + then_by",
      "as the "..data.label.." value in then_by",
      2,
      true,
      function(value, assert_errors)
        local obj = linq{"foo", "bar"}
          :order_by(function() return "hello world" end)
          :then_by(function(v) if v == data.value then return value else return v end end)
        ;
        assert_errors(function()
          iterate(obj)
        end)
      end
    )
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("to_array, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):to_array()
      assert.contents_equals(get_test_strings(), got, "result of 'to_array'")
    end)
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("to_stack, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):to_stack()
      local expected = get_test_strings()--[[@as string[]|{size: integer}]]
      expected.size = #expected
      assert.contents_equals(expected, got, "result of 'to_stack'")
    end)
  end

  add_function_validation_test("to_dict", "key value pair selector", false, function(kvp_selector)
    linq{}:to_dict(kvp_selector)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("to_dict, self has "..outer.label, function()
      local got = outer.make_obj{{k = "hello", v = "world"}, {k = "foo", v = "bar"}}:to_dict(function(value)
        return value.k, value.v
      end)
      assert.contents_equals({hello = "world", foo = "bar"}, got, "result of 'to_dict'")
    end)

    add_test("to_dict with selector using index arg, self has "..outer.label, function()
      local obj = outer.make_obj(get_test_strings())
      assert_sequential_helper(obj, obj.to_dict, function(value) return value, value end)
    end)
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_selected_value_validation_test(
      "to_dict",
      "as the first value, self has "..outer.label, "key value pair selector",
      function(assert_selector_errors)
        local obj = linq{"foo"}
        assert_selector_errors(function()
          obj:to_dict(function() return nil, "bar" end)
        end)
      end,
      1
    )

    add_selected_value_validation_test(
      "to_dict",
      "as the second value, self has "..outer.label, "key value pair selector",
      function(assert_selector_errors)
        local obj = linq{"foo"}
        assert_selector_errors(function()
          obj:to_dict(function() return "bar", nil end)
        end)
      end,
      2
    )
  end

  add_name_validation_test("to_linked_list", true, function(name)
    linq{}:to_linked_list(name)
  end)

  add_track_liveliness_validation_test("to_linked_list", true, function(track_liveliness)
    linq{}:to_linked_list(nil, track_liveliness)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    for _, data in ipairs{
      {label = "tracking liveliness, default name", track_liveliness = true, name = nil},
      {label = "not tracking liveliness, default name", track_liveliness = false, name = nil},
      {label = "tracking liveliness, non default name", track_liveliness = true, name = "foo"},
      {label = "not tracking liveliness, non default name", track_liveliness = false, name = "foo"},
    }
    do
      add_test("to_linked_list 3 values, "..data.label..", self has "..outer.label, function()
        local nodes = {{foo = 100}, {foo = 200}, {foo = 300}}
        local got_list = outer.make_obj(nodes)
          :to_linked_list(data.name, data.track_liveliness)
        ;
        local expected = ll.new_list(data.name, data.track_liveliness)
        ll.append(expected, {foo = 100})
        ll.append(expected, {foo = 200})
        ll.append(expected, {foo = 300})
        expected.alive_nodes = assert.do_not_compare_flag
        assert.contents_equals(expected, got_list)
        -- since we can't compare the alive_nodes lookup table, do it using the 'is_alive' function
        if data.track_liveliness then
          for i, node in ipairs(nodes) do
            local got = ll.is_alive(got_list, node)
            assert.equals(true, got, "result of 'is_alive' for node #"..i)
          end
        else
          assert.errors(
            "Attempt to check liveliness for a node in a linked list that does not track liveliness.",
            function()
              ll.is_alive(got_list, nodes[1])
            end
          )
        end
      end)
    end
  end

  add_function_validation_test("to_lookup", "key selector", true, function(key_selector)
    linq{}:to_lookup(key_selector)
  end)

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_test("to_lookup, "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):to_lookup()
      assert.contents_equals({foo = true, bar = true, [false] = true, baz = true}, got, "result of 'to_lookup'")
    end)

    add_test("to_lookup with key_selector, self has "..outer.label, function()
      local got = outer.make_obj(get_test_strings()):to_lookup(function(value)
        if type(value) == "string" then
          return value:sub(1, 2)
        end
        return value
      end)
      assert.contents_equals({fo = true, ba = true, [false] = true}, got, "result of 'to_lookup'")
    end)

    add_test("to_lookup with key_selector using index arg, self has "..outer.label, function()
      local obj = outer.make_obj(get_test_strings())
      assert_sequential_helper(obj, obj.to_lookup, function(value) return value end)
    end)
  end

  for _, outer in ipairs(known_or_unknown_count_dataset) do
    add_selected_value_validation_test(
      "to_lookup",
      "self has "..outer.label,
      "key selector",
      function(assert_selector_errors)
        local obj = linq{"foo"}
        assert_selector_errors(function()
          obj:to_lookup(function() return nil end)
        end)
      end
    )
  end

  add_collection_validation_test("union", "collection", false, function(collection)
    linq{}:union(collection)
  end)

  add_collection_validation_test("union_by", "collection", false, function(collection)
    linq{}:union_by(collection, function(value) return value end)
  end)

  add_function_validation_test("union_by", "key selector", false, function(key_selector)
    linq{}:union_by({}, key_selector)
  end)

  -- union
  for _, data in ipairs{
    {
      label = "2 empty collections",
      outer_values = {},
      inner_values = {},
      expected = {},
    },
    {
      label = "all unique values",
      outer_values = get_test_strings(),
      inner_values = {"hello", "world"},
      expected = {"foo", "bar", false, "baz", "hello", "world"},
    },
    {
      label = "one duplicate between collections",
      outer_values = {"foo", "bar"},
      inner_values = {"hello", "bar", "world"},
      expected = {"foo", "bar", "hello", "world"},
    },
    {
      label = "all duplicate values",
      outer_values = get_test_strings(),
      inner_values = get_test_strings(),
      expected = get_test_strings(),
    },
    {
      label = "one duplicate within each same collection",
      outer_values = {"foo", "bar", "bar"},
      inner_values = {"hello", "hello", "world"},
      expected = {"foo", "bar", "hello", "world"},
    },
    {
      label = "duplicates everywhere",
      outer_values = {"foo", "bar", "bar"},
      inner_values = {"hello", "world", "foo", "bar", "bar"},
      expected = {"foo", "bar", "hello", "world"},
    },
    {
      label = "duplicates everywhere with key_selector",
      outer_values = {"foo", "bar", "baz"},
      inner_values = {"hello", "world", "for", "big", "bat"},
      key_selector = function(value) return value:sub(1, 1) end,
      expected = {"foo", "bar", "hello", "world"},
    },
  }
  do
    for _, outer in ipairs(known_or_unknown_count_dataset) do
      for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
        local func_name = data.key_selector and "union_by" or "union"
        add_test(func_name.." "..data.label.." with "..inner.label..", self has "..outer.label, function()
          local collection = inner.make_obj(data.inner_values)
          local obj = outer.make_obj(data.outer_values)
          if data.key_selector then
            obj = obj:union_by(collection, data.key_selector)
          else
            obj = obj:union(collection)
          end
          local got_count = obj.__count
          assert.equals(nil, got_count, "internal __count after '"..func_name.."'")
          assert_iteration(obj, data.expected)
        end)
      end
    end
  end

  add_test("union makes __count unknown", function()
    local obj = linq(get_test_strings()):union{"hello", "world"}
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_test("union_by makes __count unknown", function()
    local obj = linq(get_test_strings()):union_by({"hello", "world"}, function(value) return value end)
    local got = obj.__count
    assert.equals(nil, got, "internal __count")
  end)

  add_selected_value_validation_test("union_by", "in outer", "key selector", function(assert_selector_errors)
    local obj = linq{"foo"}:union_by({}, function() return nil end)
    assert_selector_errors(function()
      iterate(obj)
    end)
  end)

  for _, inner in ipairs(array_or_obj_with_known_or_unknown_count_dataset) do
    add_selected_value_validation_test(
      "union_by",
      "in inner, inner is "..inner.label,
      "key selector",
      function(assert_selector_errors)
        local obj = linq{}:union_by(inner.make_obj{"foo"}, function() return nil end)
        assert_selector_errors(function()
          iterate(obj)
        end)
      end
    )
  end

  add_condition_validation_test("where", false, function(condition)
    linq{}:where(condition)
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
