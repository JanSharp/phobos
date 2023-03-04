
local framework = require("test_framework")
local assert = require("assert")
local tutil = require("testing_util")

local ill = require("indexed_linked_list")

local util = require("util")

local function make_test_list(intrusive, values)
  local list = ill.new(intrusive)
  for _, value in ipairs(values) do
    ill.append(list, value)
  end
  return list
end

do
  local scope = framework.scope:new_scope("indexed_linked_list")

  local function add_test(name, func)
    scope:add_test(name, func)
  end

  -- This is a lot of copy paste from linked_list, but considering how much of a (mental) mess
  -- indexed_linked_list is at this point I have no interest in changing it

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
    local data_copy = util.copy(data)
    add_test("iterate list with "..data_copy.label, function()
      local list = make_test_list(true, data_copy.values)
      local got_iterator = ill.iterate(list)
      tutil.assert_iteration(data_copy.values, got_iterator)
    end)

    add_test("iterate_reverse list with "..data.label, function()
      local list = make_test_list(true, data.values)
      local got_iterator = ill.iterate_reverse(list)
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
      local list = make_test_list(true, data.values)
      local got_iterator = ill.iterate(list, data.start_at, data.stop_at)
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
      local list = make_test_list(true, data.values)
      local got_iterator = ill.iterate_reverse(list, data.start_at, data.stop_at)
      tutil.assert_iteration(data.expected, got_iterator)
    end)
  end
end
