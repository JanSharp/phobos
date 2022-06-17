
local framework = require("test_framework")
local assert = require("assert")

local number_ranges = require("number_ranges")

local range_type = number_ranges.range_type
local inc = number_ranges.inclusive
local exc = number_ranges.exclusive

local function make_ranges(type, values)
  local ranges = {inc(-1/0)}
  local len = #values
  for i, value in ipairs(values) do
    if i == len then
      ranges[i + 1] = exc(value)
    else
      ranges[i + 1] = inc(value, type)
    end
  end
  return ranges
end

do
  local main_scope = framework.scope:new_scope("number_ranges")

  do
    local compare_point_scope = main_scope:new_scope("compare_point")

    local function add_test(name, func)
      compare_point_scope:add_test(name, func)
    end

    local compare_point = number_ranges.compare_point

    add_test("compare_point nil base, nil other", function()
      local got = compare_point(nil, nil)
      assert.equals(0, got)
    end)

    add_test("compare_point nil base, non nil other", function()
      local got = compare_point(nil, inc(0))
      assert.equals(-1, got)
    end)

    add_test("compare_point non nil base, non nil other", function()
      local got = compare_point(inc(0), nil)
      assert.equals(1, got)
    end)

    add_test("compare_point same value, inclusive base, inclusive other", function()
      local got = compare_point(inc(0), inc(0))
      assert.equals(0, got)
    end)

    add_test("compare_point same value, exclusive base, exclusive other", function()
      local got = compare_point(exc(0), exc(0))
      assert.equals(0, got)
    end)

    add_test("compare_point same value, inclusive base, exclusive other", function()
      local got = compare_point(inc(0), exc(0))
      assert.equals(1, got)
    end)

    add_test("compare_point same value, exclusive base, inclusive other", function()
      local got = compare_point(exc(0), inc(0))
      assert.equals(-1, got)
    end)

    add_test("compare_point 0 base, -1 other", function()
      local got = compare_point(inc(0), inc(-1))
      assert.equals(-1, got)
    end)

    add_test("compare_point 0 base, 1 other", function()
      local got = compare_point(inc(0), inc(1))
      assert.equals(1, got)
    end)
  end

  do
    local union_range_type_scope = main_scope:new_scope("union_range_type")

    local function add_test(name, func)
      union_range_type_scope:add_test(name, func)
    end

    local union_range_type = number_ranges.union_range_type
    local type_str_lut = number_ranges.range_type_str_lut

    for _, data in ipairs{
      {one = range_type.nothing, two = range_type.nothing, result = range_type.nothing},
      {one = range_type.nothing, two = range_type.everything, result = range_type.everything},
      {one = range_type.nothing, two = range_type.integral, result = range_type.integral},
      {one = range_type.nothing, two = range_type.non_integral, result = range_type.non_integral},
      {one = range_type.everything, two = range_type.nothing, result = range_type.everything},
      {one = range_type.everything, two = range_type.everything, result = range_type.everything},
      {one = range_type.everything, two = range_type.integral, result = range_type.everything},
      {one = range_type.everything, two = range_type.non_integral, result = range_type.everything},
      {one = range_type.integral, two = range_type.nothing, result = range_type.integral},
      {one = range_type.integral, two = range_type.everything, result = range_type.everything},
      {one = range_type.integral, two = range_type.integral, result = range_type.integral},
      {one = range_type.integral, two = range_type.non_integral, result = range_type.everything},
      {one = range_type.non_integral, two = range_type.nothing, result = range_type.non_integral},
      {one = range_type.non_integral, two = range_type.everything, result = range_type.everything},
      {one = range_type.non_integral, two = range_type.integral, result = range_type.everything},
      {one = range_type.non_integral, two = range_type.non_integral, result = range_type.non_integral},
    }
    do
      add_test("union_range_type "..type_str_lut[data.one].." "..type_str_lut[data.two], function()
        local got = union_range_type(inc(0, data.one), inc(0, data.two))
        assert.equals(data.result, got)
      end)
    end
  end

  do
    local union_range_scope = main_scope:new_scope("union_range")

    local function add_test(name, func)
      union_range_scope:add_test(name, func)
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
    --
    -- 11
    --  |---<---->>
    --  |-------->>
    -- ab-a-b(inf)
    --
    -- 12
    --  |-------->>
    --   |-<
    -- a-b-b

    local function perform_union_range(ranges, from_value, to_value)
      return number_ranges.union_range(
        ranges,
        inc(from_value, range_type.non_integral),
        to_value and exc(to_value) or nil
      )
    end

    -- 1
    --  |---<---->>
    -- |-<
    -- b-a-b-a
    add_test("union_range b-a-b-a", function()
      local ranges = make_ranges(range_type.integral, {2, 6})
      local got = perform_union_range(ranges, 1, 3)
      assert.contents_equals({
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
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
        inc(-1/0),
        inc(2, range_type.everything),
        exc(6),
      }, got)
    end)

    -- 11
    --  |---<---->>
    --  |-------->>
    -- ab-a-b(inf)
    add_test("union_range ab-a-b(inf)", function()
      local ranges = make_ranges(range_type.integral, {2, 6})
      local got = perform_union_range(ranges, 2, nil)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.everything),
        exc(6, range_type.non_integral),
      }, got)
    end)

    -- 12
    --  |-------->>
    --   |-<
    -- a-b-b
    add_test("union_range a-b-b", function()
      local ranges = {inc(-1/0, range_type.integral)}
      local got = perform_union_range(ranges, 3, 5)
      assert.contents_equals({
        inc(-1/0, range_type.integral),
        inc(3, range_type.everything),
        exc(5, range_type.integral),
      }, got)
    end)
  end

  do
    local union_ranges_scope = main_scope:new_scope("union_ranges")

    local function add_test(name, func)
      union_ranges_scope:add_test(name, func)
    end

    -- 1
    -- |--<---<-->>
    -- |-<---<--->>
    -- ab-b-a-b-a
    --
    -- 2
    -- |--<---<-->>
    -- |-<-----<->>
    -- ab-b-a-a-b
    --
    -- 3
    -- |--<---<-->>
    -- |---<-<--->>
    -- ab-a-b-b-a
    --
    -- 4
    -- |--<---<-->>
    -- |---<---<->>
    -- ab-a-b-a-b
    --
    -- 5
    -- |--<---<-->>
    -- |--<---<-->>
    -- ab-ab-ab
    --
    -- 6
    -- |--<---<-->>
    -- |--<--<--->>
    -- ab-ab-b-a
    --
    -- 7
    -- |--<---<-->>
    -- |--<----<->>
    -- ab-ab-a-b
    --
    -- 8
    -- |--<---<-->>
    -- |-<----<-->>
    -- ab-b-a-ab
    --
    -- 9
    -- |--<---<-->>
    -- |---<--<-->>
    -- ab-a-b-ab

    -- 1
    -- |--<---<-->>
    -- |-<---<--->>
    -- ab-b-a-b-a
    add_test("union_ranges ab-b-a-b-a", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {1, 5})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(1, range_type.non_integral),
        inc(2, range_type.everything),
        exc(5, range_type.integral),
        exc(6),
      }, got)
    end)

    -- 2
    -- |--<---<-->>
    -- |-<-----<->>
    -- ab-b-a-a-b
    add_test("union_ranges ab-b-a-a-b", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {1, 7})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(1, range_type.non_integral),
        inc(2, range_type.everything),
        exc(6, range_type.non_integral),
        exc(7),
      }, got)
    end)

    -- 3
    -- |--<---<-->>
    -- |---<-<--->>
    -- ab-a-b-b-a
    add_test("union_ranges ab-a-b-b-a", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {3, 5})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.integral),
        inc(3, range_type.everything),
        exc(5, range_type.integral),
        exc(6),
      }, got)
    end)

    -- 4
    -- |--<---<-->>
    -- |---<---<->>
    -- ab-a-b-a-b
    add_test("union_ranges ab-a-b-a-b", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {3, 7})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.integral),
        inc(3, range_type.everything),
        exc(6, range_type.non_integral),
        exc(7),
      }, got)
    end)

    -- 5
    -- |--<---<-->>
    -- |--<---<-->>
    -- ab-ab-ab
    add_test("union_ranges ab-ab-ab", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {2, 6})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.everything),
        exc(6),
      }, got)
    end)

    -- 6
    -- |--<---<-->>
    -- |--<--<--->>
    -- ab-ab-b-a
    add_test("union_ranges ab-ab-b-a", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {2, 5})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.everything),
        exc(5, range_type.integral),
        exc(6),
      }, got)
    end)

    -- 7
    -- |--<---<-->>
    -- |--<----<->>
    -- ab-ab-a-b
    add_test("union_ranges ab-ab-a-b", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {2, 7})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.everything),
        exc(6, range_type.non_integral),
        exc(7),
      }, got)
    end)

    -- 8
    -- |--<---<-->>
    -- |-<----<-->>
    -- ab-b-a-ab
    add_test("union_ranges ab-b-a-ab", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {1, 6})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(1, range_type.non_integral),
        inc(2, range_type.everything),
        exc(6),
      }, got)
    end)

    -- 9
    -- |--<---<-->>
    -- |---<--<-->>
    -- ab-a-b-ab
    add_test("union_ranges ab-a-b-ab", function()
      local left_ranges = make_ranges(range_type.integral, {2, 6})
      local right_ranges = make_ranges(range_type.non_integral, {3, 6})
      local got = number_ranges.union_ranges(left_ranges, right_ranges)
      assert.contents_equals({
        inc(-1/0),
        inc(2, range_type.integral),
        inc(3, range_type.everything),
        exc(6),
      }, got)
    end)
  end

  do
    local normalize_scope = main_scope:new_scope("normalize")

    local function add_test(name, func)
      normalize_scope:add_test(name, func)
    end

    local normalize = number_ranges.normalize

    add_test("normalize removing 0 points", function()
      local ranges = {
        inc(-1/0),
        inc(1, range_type.everything),
        exc(10),
      }
      local got = normalize(number_ranges.copy_ranges(ranges))
      assert.contents_equals(ranges, got)
    end)

    add_test("normalize removing 1 point", function()
      local ranges = {
        inc(-1/0),
        inc(1, range_type.everything),
        inc(2, range_type.everything),
        exc(10),
      }
      local got = normalize(number_ranges.copy_ranges(ranges))
      table.remove(ranges, 3)
      assert.contents_equals(ranges, got)
    end)

    add_test("normalize removing the last point", function()
      local ranges = {
        inc(-1/0),
        exc(10),
      }
      local got = normalize(number_ranges.copy_ranges(ranges))
      table.remove(ranges, 2)
      assert.contents_equals(ranges, got)
    end)

    add_test("normalize removing 2 points in a row", function()
      local ranges = {
        inc(-1/0),
        inc(1, range_type.everything),
        inc(2, range_type.everything),
        inc(3, range_type.everything),
        exc(10),
      }
      local got = normalize(number_ranges.copy_ranges(ranges))
      table.remove(ranges, 4)
      table.remove(ranges, 3)
      assert.contents_equals(ranges, got)
    end)

    add_test("normalize removing 2 separate points", function()
      local ranges = {
        inc(-1/0),
        inc(1, range_type.everything),
        inc(2, range_type.everything),
        inc(3, range_type.nothing),
        inc(4, range_type.integral),
        inc(5, range_type.integral),
        exc(10),
      }
      local got = normalize(number_ranges.copy_ranges(ranges))
      table.remove(ranges, 6)
      table.remove(ranges, 3)
      assert.contents_equals(ranges, got)
    end)
  end

  do
    local contains_range_type_scope = main_scope:new_scope("contains_range_type")

    local function add_test(name, func)
      contains_range_type_scope:add_test(name, func)
    end

    local contains_range_type = number_ranges.contains_range_type
    local type_str_lut = number_ranges.range_type_str_lut

    for _, data in ipairs{
      {base = range_type.nothing, other = range_type.nothing, result = true},
      {base = range_type.nothing, other = range_type.everything, result = false},
      {base = range_type.nothing, other = range_type.integral, result = false},
      {base = range_type.nothing, other = range_type.non_integral, result = false},
      {base = range_type.everything, other = range_type.nothing, result = true},
      {base = range_type.everything, other = range_type.everything, result = true},
      {base = range_type.everything, other = range_type.integral, result = true},
      {base = range_type.everything, other = range_type.non_integral, result = true},
      {base = range_type.integral, other = range_type.nothing, result = true},
      {base = range_type.integral, other = range_type.everything, result = false},
      {base = range_type.integral, other = range_type.integral, result = true},
      {base = range_type.integral, other = range_type.non_integral, result = false},
      {base = range_type.non_integral, other = range_type.nothing, result = true},
      {base = range_type.non_integral, other = range_type.everything, result = false},
      {base = range_type.non_integral, other = range_type.integral, result = false},
      {base = range_type.non_integral, other = range_type.non_integral, result = true},
    }
    do
      add_test("contains_range_type "..type_str_lut[data.base]
        ..(data.result and " contains " or " does not contain ")
        ..type_str_lut[data.other],
      function()
        local got = contains_range_type(data.base, data.other)
        assert.equals(data.result, got)
      end)
    end
  end

  do
    local contains_ranges_scope = main_scope:new_scope("contains_ranges")

    local function add_test(name, func)
      contains_ranges_scope:add_test(name, func)
    end

    local contains_ranges = number_ranges.contains_ranges

    add_test("contains_ranges identical base and other", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges longer other", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(1, range_type.everything), exc(11)}
      local got = contains_ranges(base, other)
      assert.equals(false, got)
    end)

    add_test("contains_ranges shorter other", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(1, range_type.everything), exc(9)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges shorter other also starting later", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(2, range_type.everything), exc(9)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges other overlapping with multiple base ranges", function()
      local base = {inc(-1/0), inc(1, range_type.everything), inc(5, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(2, range_type.everything), exc(9)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges with one non containing range in the middle of one big overlap", function()
      local base = {inc(-1/0), inc(1, range_type.everything), inc(3), inc(5, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(2, range_type.everything), exc(9)}
      local got = contains_ranges(base, other)
      assert.equals(false, got)
    end)

    add_test("contains_ranges multiple other overlapping with the same base", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(2, range_type.everything), inc(5), inc(7, range_type.everything), exc(9)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges uses contains_range_type", function()
      local base = {inc(-1/0), inc(1, range_type.everything), exc(10)}
      local other = {inc(-1/0), inc(1, range_type.integral), exc(10)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges just with -inf", function()
      local base = {inc(-1/0)}
      local other = {inc(-1/0)}
      local got = contains_ranges(base, other)
      assert.equals(true, got)
    end)

    add_test("contains_ranges just with -inf with non containing types", function()
      local base = {inc(-1/0)}
      local other = {inc(-1/0, range_type.non_integral)}
      local got = contains_ranges(base, other)
      assert.equals(false, got)
    end)
  end
end
