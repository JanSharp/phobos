
local framework = require("test_framework")
local assert = require("assert")

local number_ranges = require("number_ranges")

local range_type = number_ranges.range_type
local inc = number_ranges.inclusive
local exc = number_ranges.exclusive

local function make_ranges(type, values)
  local ranges = {}
  local len = #values
  for i, value in ipairs(values) do
    if i == len then
      ranges[i] = exc(value)
    else
      ranges[i] = inc(value, type)
    end
  end
  return ranges
end

do
  local main_scope = framework.scope:new_scope("number_ranges")

  local function add_test(name, func)
    main_scope:add_test(name, func)
  end

  -- union_range test cases:
  --
  -- 1
  --  |---<---->>
  -- |-<
  -- b-a-b-a
  --
  -- 2
  --  |---<---->>
  -- |-----<
  -- b-a-a-b
  --
  -- 3
  --  |---<---->>
  --   |---<
  -- a-b-a-b
  --
  -- 4
  --  |---<---->>
  --   |-<
  -- a-b-b-a
  --
  -- 5
  --  |-<-<---->>
  --   |-<
  -- a-b-a-b-a
  --
  -- 6
  --  |-<-<---->>
  --   |---<
  -- a-b-a-a-b
  --
  -- 7
  --  |-<-<---->>
  -- |---<
  -- b-a-a-b-a
  --
  -- 8
  --  |---<---->>
  --  |--<
  -- ab-b-a
  --
  -- 9
  --  |---<---->>
  --   |--<
  -- a-b-ab
  --
  -- 10
  --  |---<---->>
  --  |---<
  -- ab-ab

  local function perform_union_range(ranges, from_value, to_value)
    return number_ranges.union_range(ranges, inc(from_value, range_type.non_integral), exc(to_value))
  end

  -- 1
  --  |---<---->>
  -- |-<
  -- b-a-b-a
  add_test("union_range b-a-b-a", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 1, 3)
    assert.contents_equals({
      inc(1, range_type.non_integral),
      inc(2, range_type.everything),
      exc(3, range_type.integral),
      exc(6),
    }, got)
  end)

  -- 2
  --  |---<---->>
  -- |-----<
  -- b-a-a-b
  add_test("union_range b-a-a-b", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 1, 7)
    assert.contents_equals({
      inc(1, range_type.non_integral),
      inc(2, range_type.everything),
      exc(6, range_type.non_integral),
      exc(7),
    }, got)
  end)

  -- 3
  --  |---<---->>
  --   |---<
  -- a-b-a-b
  add_test("union_range a-b-a-b", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 3, 7)
    assert.contents_equals({
      inc(2, range_type.integral),
      inc(3, range_type.everything),
      exc(6, range_type.non_integral),
      exc(7),
    }, got)
  end)

  -- 4
  --  |---<---->>
  --   |-<
  -- a-b-b-a
  add_test("union_range a-b-b-a", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 3, 5)
    assert.contents_equals({
      inc(2, range_type.integral),
      inc(3, range_type.everything),
      exc(5, range_type.integral),
      exc(6),
    }, got)
  end)

  -- 5
  --  |-<-<---->>
  --   |-<
  -- a-b-a-b-a
  add_test("union_range a-b-a-b-a", function()
    local ranges = make_ranges(range_type.integral, {2, 4, 6})
    local got = perform_union_range(ranges, 3, 5)
    assert.contents_equals({
      inc(2, range_type.integral),
      inc(3, range_type.everything),
      inc(4, range_type.everything),
      exc(5, range_type.integral),
      exc(6),
    }, got)
  end)

  -- 6
  --  |-<-<---->>
  --   |---<
  -- a-b-a-a-b
  add_test("union_range a-b-a-a-b", function()
    local ranges = make_ranges(range_type.integral, {2, 4, 6})
    local got = perform_union_range(ranges, 3, 7)
    assert.contents_equals({
      inc(2, range_type.integral),
      inc(3, range_type.everything),
      inc(4, range_type.everything),
      exc(6, range_type.non_integral),
      exc(7),
    }, got)
  end)

  -- 7
  --  |-<-<---->>
  -- |---<
  -- b-a-a-b-a
  add_test("union_range b-a-a-b-a", function()
    local ranges = make_ranges(range_type.integral, {2, 4, 6})
    local got = perform_union_range(ranges, 1, 5)
    assert.contents_equals({
      inc(1, range_type.non_integral),
      inc(2, range_type.everything),
      inc(4, range_type.everything),
      exc(5, range_type.integral),
      exc(6),
    }, got)
  end)

  -- 8
  --  |---<---->>
  --  |--<
  -- ab-b-a
  add_test("union_range ab-b-a", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 2, 5)
    assert.contents_equals({
      inc(2, range_type.everything),
      exc(5, range_type.integral),
      exc(6),
    }, got)
  end)

  -- 9
  --  |---<---->>
  --   |--<
  -- a-b-ab
  add_test("union_range a-b-ab", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 3, 6)
    assert.contents_equals({
      inc(2, range_type.integral),
      inc(3, range_type.everything),
      exc(6),
    }, got)
  end)

  -- 10
  --  |---<---->>
  --  |---<
  -- ab-ab
  add_test("union_range ab-ab", function()
    local ranges = make_ranges(range_type.integral, {2, 6})
    local got = perform_union_range(ranges, 2, 6)
    assert.contents_equals({
      inc(2, range_type.everything),
      exc(6),
    }, got)
  end)
end
