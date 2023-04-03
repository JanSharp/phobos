
local framework = require("test_framework")
local assert = require("assert")
local tutil = require("testing_util")

local ll = require("linked_list")

local util = require("util")

local track_liveliness = nil

local function make_expected_list(elements, next_key, prev_key)
  next_key = next_key or "next_foo"
  prev_key = prev_key or "prev_foo"
  local result = {
    first = elements[1],
    last = elements[#elements],
    next_key = next_key,
    prev_key = prev_key,
    alive_nodes = assert.do_not_compare_flag,
  }
  local prev
  for _, elem in ipairs(elements) do
    if prev then
      prev[next_key] = elem
      elem[prev_key] = prev
    end
    prev = elem
  end
  return result
end

local function make_simple_test_list(elements)
  local list = make_expected_list(elements)
  list.alive_nodes = nil
  return list
end

local function make_test_list(elements)
  if track_liveliness == nil then
    util.debug_abort("Must not use 'make_test_list' outside of an 'add_double_test' callback.")
  end
  local list = make_expected_list(elements)
  list.alive_nodes = track_liveliness and util.invert(elements) or nil
  return list
end

local function assert_is_alive_errors(list, node, msg)
  assert.errors(
    "Attempt to check liveliness for a node in a linked list that does not track liveliness.",
    function()
      ll.is_alive(list, node)
    end,
    msg
  )
end

local function assert_is_alive(list, node, expected, label)
  local got = ll.is_alive(list, node)
  assert.equals(expected, got, "result of 'is_alive' for "..label)
end

local function assert_is_alive_helper(list, node, expected, label)
  if track_liveliness == nil then
    util.debug_abort("Must not use 'assert_is_alive' outside of an 'add_double_test' callback.")
  end
  if track_liveliness then
    assert_is_alive(list, node, expected, label)
  else
    assert_is_alive_errors(list, node, label)
  end
end

do
  local scope = framework.scope:new_scope("linked_list")

  local function add_test(name, func)
    scope:add_test(name, func)
  end

  local function add_double_test(name, func)
    add_test(name.." (tracking liveliness)", function()
      track_liveliness = true
      func()
      track_liveliness = nil
    end)
    add_test(name.." (not tracking liveliness)", function()
      track_liveliness = false
      func()
      track_liveliness = nil
    end)
  end

  local new_list_params_dataset = {
    {
      label = "default name, not tracking liveliness",
      name = nil,
      expected_next_key = "next",
      expected_prev_key = "prev",
      track_liveliness = false,
    },
    {
      label = "default name, tracking liveliness",
      name = nil,
      expected_next_key = "next",
      expected_prev_key = "prev",
      track_liveliness = true,
    },
    {
      label = "custom name, not tracking liveliness",
      name = "foo",
      expected_next_key = "next_foo",
      expected_prev_key = "prev_foo",
      track_liveliness = false,
    },
    {
      label = "custom name, tracking liveliness",
      name = "foo",
      expected_next_key = "next_foo",
      expected_prev_key = "prev_foo",
      track_liveliness = true,
    },
  }

  for _, data in ipairs(new_list_params_dataset) do
    add_test("new_list, "..data.label, function()
      local got_list = ll.new_list(data.name, data.track_liveliness)
      local expected = {
        next_key = data.expected_next_key,
        prev_key = data.expected_prev_key,
        alive_nodes = data.track_liveliness and {} or nil
      }
      assert.contents_equals(expected, got_list)
    end)
  end

  for _, array_data in ipairs{
    {label = "empty array", array = {}},
    {label = "array with 1 value", array = {{foo = 100}}},
    {label = "array with 2 values", array = {{foo = 100}, {foo = 200}}},
    {label = "array with 3 values", array = {{foo = 100}, {foo = 200}, {foo = 300}}},
  }
  do
    for _, data in ipairs(new_list_params_dataset) do
      add_test(
        "from_array with "..array_data.label..", "..data.label,
        function()
          local got_list = ll.from_array(array_data.array, data.name, data.track_liveliness)
          local expected = make_expected_list(array_data.array, data.expected_next_key, data.expected_prev_key)
          assert.contents_equals(expected, got_list)
          if data.track_liveliness then
            for j, node in ipairs(array_data.array) do
              assert_is_alive(got_list, node, true, "node #"..j)
            end
          else
            assert_is_alive_errors(got_list, {foo = 100}, "a random node")
          end
        end
      )
    end
  end

  for _, iterator_data in ipairs{
    {label = "iterator for 0 values", values = {}},
    {label = "iterator for 1 values", values = {{foo = 100}}},
    {label = "iterator for 2 values", values = {{foo = 100}, {foo = 200}}},
    {label = "iterator for 3 values", values = {{foo = 100}, {foo = 200}, {foo = 300}}},
  }
  do
    for _, data in ipairs(new_list_params_dataset) do
      local i = 0
      local function iterator()
        i = i + 1
        return iterator_data.values[i]
      end
      add_test(
        "from_iterator with "..iterator_data.label..", "..data.label,
        function()
          local got_list = ll.from_iterator(iterator, data.name, data.track_liveliness)
          local expected = make_expected_list(iterator_data.values, data.expected_next_key, data.expected_prev_key)
          assert.contents_equals(expected, got_list)
          if data.track_liveliness then
            for j, node in ipairs(iterator_data.values) do
              assert_is_alive(got_list, node, true, "node #"..j)
            end
          else
            assert_is_alive_errors(got_list, {foo = 100}, "a random node")
          end
        end
      )
    end
  end

  add_test("is_alive errors with lists not tracking liveliness", function()
    local list = ll.new_list("foo", false)
    assert.errors(
      "Attempt to check liveliness for a node in a linked list that does not track liveliness.",
      function()
        ll.is_alive(list, {foo = 100})
      end
    )
  end)

  add_test("is_alive returns false for a node not in a given list", function()
    local list = ll.new_list("foo", true)
    local got = ll.is_alive(list, {foo = 100})
    assert.equals(false, got, "result of 'is_alive'")
  end)

  -- iterate and iterate_reverse
  for _, data in ipairs{
    {label = "no nodes", values = {}, reverse = {}},
    (function()
      local values = {{foo = 100}}
      local reverse = {values[1]}
      return {label = "1 node", values = values, reverse = reverse}
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}}
      local reverse = {values[2], values[1]}
      return {label = "2 nodes", values = values, reverse = reverse}
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}}
      local reverse = {values[3], values[2], values[1]}
      return {label = "3 nodes", values = values, reverse = reverse}
    end)(),
  }
  do
    add_test("iterate list with "..data.label, function()
      local list = make_simple_test_list(data.values)
      local got_iterator = ll.iterate(list, data.start_at, data.stop_at)
      tutil.assert_iteration(data.expected or data.values, got_iterator)
    end)

    add_test("iterate_reverse list with "..data.label, function()
      local list = make_simple_test_list(data.values)
      local got_iterator = ll.iterate_reverse(list, data.start_at, data.stop_at)
      tutil.assert_iteration(data.reverse, got_iterator)
    end)
  end

  -- iterate
  for _, data in ipairs{
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = util.shallow_copy(values)
      table.remove(expected, 1)
      return {
        label = "5 nodes, starting at 2nd node",
        values = values,
        start_at = values[2],
        expected = expected,
      }
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = util.shallow_copy(values)
      expected[5] = nil
      return {
        label = "5 nodes, stopping at 4th node",
        values = values,
        stop_at = values[4],
        expected = expected,
      }
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = util.shallow_copy(values)
      expected[5] = nil
      table.remove(expected, 1)
      return {
        label = "5 nodes, starting at 2nd node, stopping at 4th node",
        values = values,
        start_at = values[2],
        stop_at = values[4],
        expected = expected,
      }
    end)(),
  }
  do
    add_test("iterate list with "..data.label, function()
      local list = make_simple_test_list(data.values)
      local got_iterator = ll.iterate(list, data.start_at, data.stop_at)
      tutil.assert_iteration(data.expected, got_iterator)
    end)
  end

  -- iterate_reverse
  for _, data in ipairs{
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = {values[4], values[3], values[2], values[1]}
      return {
        label = "5 nodes, starting at 4th node",
        values = values,
        start_at = values[4],
        expected = expected,
      }
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = {values[5], values[4], values[3], values[2]}
      return {
        label = "5 nodes, stopping at 2nd node",
        values = values,
        stop_at = values[2],
        expected = expected,
      }
    end)(),
    (function()
      local values = {{foo = 100}, {foo = 200}, {foo = 300}, {foo = 400}, {foo = 500}}
      local expected = {values[4], values[3], values[2]}
      return {
        label = "5 nodes, starting at 4th node, stopping at 2nd node",
        values = values,
        start_at = values[4],
        stop_at = values[2],
        expected = expected,
      }
    end)(),
  }
  do
    add_test("iterate_reverse list with "..data.label, function()
      local list = make_simple_test_list(data.values)
      local got_iterator = ll.iterate_reverse(list, data.start_at, data.stop_at)
      tutil.assert_iteration(data.expected, got_iterator)
    end)
  end

  add_double_test("append to empty list adds the node", function()
    local got_list = make_test_list{}
    local node = {foo = 100}
    ll.append(got_list, node)
    local expected = make_expected_list{{foo = 100}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, node, true, "appended node after appending")
  end)

  add_double_test("append to initially empty list twice", function()
    local got_list = make_test_list{}
    ll.append(got_list, {foo = 100})
    local second_node = {foo = 200}
    ll.append(got_list, second_node)
    local expected = make_expected_list{{foo = 100}, {foo = 200}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, second_node, true, "second appended node after appending")
  end)

  add_double_test("prepend to empty list adds the node", function()
    local got_list = make_test_list{}
    local node = {foo = 100}
    ll.prepend(got_list, node)
    local expected = make_expected_list{{foo = 100}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, node, true, "prepended node after prepending")
  end)

  add_double_test("prepend to initially empty list twice", function()
    local got_list = make_test_list{}
    ll.prepend(got_list, {foo = 100})
    local second_node = {foo = 200}
    ll.prepend(got_list, second_node)
    local expected = make_expected_list{{foo = 200}, {foo = 100}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, second_node, true, "second prepended node after prepending")
  end)

  add_double_test("insert_after the first node in a list with 2 nodes inserts in the middle", function()
    local first_node = {foo = 100}
    local got_list = make_test_list{first_node, {foo = 200}}
    local inserted_node = {foo = 300}
    ll.insert_after(got_list, first_node, inserted_node)
    local expected = make_expected_list{{foo = 100}, {foo = 300}, {foo = 200}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_after the last node in a list (with 2 nodes) appends", function()
    local last_node = {foo = 200}
    local got_list = make_test_list{{foo = 100}, last_node}
    local inserted_node = {foo = 300}
    ll.insert_after(got_list, last_node, inserted_node)
    local expected = make_expected_list{{foo = 100}, {foo = 200}, {foo = 300}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_after nil (in a list with 2 nodes) prepends", function()
    local got_list = make_test_list{{foo = 100}, {foo = 200}}
    local inserted_node = {foo = 300}
    ll.insert_after(got_list, nil, inserted_node)
    local expected = make_expected_list{{foo = 300}, {foo = 100}, {foo = 200}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_after nil (in an empty list) adds the node", function()
    local got_list = make_test_list{}
    local inserted_node = {foo = 300}
    ll.insert_after(got_list, nil, inserted_node)
    local expected = make_expected_list{{foo = 300}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_after where both the base node and the new node are the same errors", function()
    local node = {foo = 100}
    local list = make_expected_list{node}
    assert.errors("Inserting a node after itself does not make sense.", function()
      ll.insert_after(list, node, node)
    end)
  end)

  add_double_test("insert_before the last node in a list with 2 nodes inserts in the middle", function()
    local last_node = {foo = 200}
    local got_list = make_test_list{{foo = 100}, last_node}
    local inserted_node = {foo = 300}
    ll.insert_before(got_list, last_node, inserted_node)
    local expected = make_expected_list{{foo = 100}, {foo = 300}, {foo = 200}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_before the first node in a list (with 2 nodes) prepends", function()
    local first_node = {foo = 100}
    local got_list = make_test_list{first_node, {foo = 200}}
    local inserted_node = {foo = 300}
    ll.insert_before(got_list, first_node, inserted_node)
    local expected = make_expected_list{{foo = 300}, {foo = 100}, {foo = 200}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_before nil (in a list with 2 nodes) appends", function()
    local got_list = make_test_list{{foo = 100}, {foo = 200}}
    local inserted_node = {foo = 300}
    ll.insert_before(got_list, nil, inserted_node)
    local expected = make_expected_list{{foo = 100}, {foo = 200}, {foo = 300}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_before nil (in an empty list) adds the node", function()
    local got_list = make_test_list{}
    local inserted_node = {foo = 300}
    ll.insert_before(got_list, nil, inserted_node)
    local expected = make_expected_list{{foo = 300}}
    assert.contents_equals(got_list, expected)
    assert_is_alive_helper(got_list, inserted_node, true, "inserted node after inserting")
  end)

  add_double_test("insert_before where both the base node and the new node are the same errors", function()
    local node = {foo = 100}
    local list = make_expected_list{node}
    assert.errors("Inserting a node before itself does not make sense.", function()
      ll.insert_before(list, node, node)
    end)
  end)

  add_double_test("remove 1nd out of 3 nodes", function()
    local first_node = {foo = 100}
    local got_list = make_test_list{first_node, {foo = 200}, {foo = 300}}
    ll.remove(got_list, first_node)
    local expected = make_expected_list{{foo = 200}, {foo = 300}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, first_node, false, "removed node after removal")
  end)

  add_double_test("remove 2nd out of 3 nodes", function()
    local second_node = {foo = 200}
    local got_list = make_test_list{{foo = 100}, second_node, {foo = 300}}
    ll.remove(got_list, second_node)
    local expected = make_expected_list{{foo = 100}, {foo = 300}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, second_node, false, "removed node after removal")
  end)

  add_double_test("remove 3nd out of 3 nodes", function()
    local third_node = {foo = 300}
    local got_list = make_test_list{{foo = 100}, {foo = 200}, third_node}
    ll.remove(got_list, third_node)
    local expected = make_expected_list{{foo = 100}, {foo = 200}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, third_node, false, "removed node after removal")
  end)

  add_double_test("remove_range first 3 nodes out of 5", function()
    local first_node = {foo = 100}
    local second_node = {foo = 200}
    local third_node = {foo = 300}
    local got_list = make_test_list{first_node, second_node, third_node, {foo = 400}, {foo = 500}}
    ll.remove_range(got_list, first_node, third_node)
    local expected = make_expected_list{{foo = 400}, {foo = 500}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, first_node, false, "first removed node after removal")
    assert_is_alive_helper(got_list, second_node, false, "second removed node after removal")
    assert_is_alive_helper(got_list, third_node, false, "third removed node after removal")
  end)

  add_double_test("remove_range middle 3 nodes out of 5", function()
    local second_node = {foo = 200}
    local third_node = {foo = 300}
    local fourth_node = {foo = 400}
    local got_list = make_test_list{{foo = 100}, second_node, third_node, fourth_node, {foo = 500}}
    ll.remove_range(got_list, second_node, fourth_node)
    local expected = make_expected_list{{foo = 100}, {foo = 500}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, second_node, false, "second removed node after removal")
    assert_is_alive_helper(got_list, third_node, false, "third removed node after removal")
    assert_is_alive_helper(got_list, fourth_node, false, "fourth removed node after removal")
  end)

  add_double_test("remove_range last 3 nodes out of 5", function()
    local third_node = {foo = 300}
    local fourth_node = {foo = 400}
    local fifth_node = {foo = 500}
    local got_list = make_test_list{{foo = 100}, {foo = 200}, third_node, fourth_node, fifth_node}
    ll.remove_range(got_list, third_node, fifth_node)
    local expected = make_expected_list{{foo = 100}, {foo = 200}}
    assert.contents_equals(expected, got_list)
    assert_is_alive_helper(got_list, third_node, false, "third removed node after removal")
    assert_is_alive_helper(got_list, fourth_node, false, "fourth removed node after removal")
    assert_is_alive_helper(got_list, fifth_node, false, "fifth removed node after removal")
  end)

  add_test("start_tracking_liveliness marks existing nodes as alive", function()
    local list = ll.new_list("foo", false)
    local first_node = {foo = 100}
    ll.append(list, first_node)
    local second_node = {foo = 200}
    ll.append(list, second_node)
    assert_is_alive_errors(list, first_node, "first node before start_tracking_liveliness")
    assert_is_alive_errors(list, second_node, "second node before start_tracking_liveliness")
    ll.start_tracking_liveliness(list)
    assert_is_alive(list, first_node, true, "first node after start_tracking_liveliness")
    assert_is_alive(list, second_node, true, "second node after start_tracking_liveliness")
  end)

  add_test("start_tracking_liveliness enables tracking for subsequent append (and other) calls", function()
    local list = ll.new_list("foo", false)
    ll.start_tracking_liveliness(list)
    local node = {foo = 100}
    ll.append(list, node)
    assert_is_alive(list, node, true, "node added after start_tracking_liveliness")
  end)

  add_test("stop_tracking_liveliness removes tracked data", function()
    local list = ll.new_list("foo", true)
    local first_node = {foo = 100}
    ll.append(list, first_node)
    local second_node = {foo = 200}
    ll.append(list, second_node)
    assert_is_alive(list, first_node, true, "first node after stop_tracking_liveliness")
    assert_is_alive(list, second_node, true, "second node after stop_tracking_liveliness")
    ll.stop_tracking_liveliness(list)
    assert_is_alive_errors(list, first_node, "first node before stop_tracking_liveliness")
    assert_is_alive_errors(list, second_node, "second node before stop_tracking_liveliness")
  end)

  add_test("stop_tracking_liveliness enables tracking for subsequent append (and other) calls", function()
    local list = ll.new_list("foo", true)
    ll.stop_tracking_liveliness(list)
    local node = {foo = 100}
    ll.append(list, node)
    assert_is_alive_errors(list, node, "node added after stop_tracking_liveliness")
  end)
end
