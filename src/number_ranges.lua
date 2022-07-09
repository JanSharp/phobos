
local util = require("util")

local range_type = {
  nothing = 0,
  everything = 1,
  integral = 2,
  non_integral = 3,
}

local range_type_str_lut = {
  [0] = "nothing",
  [1] = "everything",
  [2] = "integral",
  [3] = "non_integral",
}

local function inclusive(value, type)
  return {
    range_type = type or range_type.nothing,
    value = value,
    inclusive = true,
  }
end

local function exclusive(value, type)
  return {
    range_type = type or range_type.nothing,
    value = value,
    inclusive = false,
  }
end

local function compare_point(base_point, other_point)
  if not base_point then
    return other_point and -1 or 0
  end
  if not other_point then
    return 1
  end
  if other_point.value < base_point.value then
    return -1
  end
  if other_point.value > base_point.value then
    return 1
  end
  if other_point.inclusive == base_point.inclusive then
    return 0
  end
  if other_point.inclusive then -- `and not base_point.inclusive` is implied/guaranteed
    return -1
  else
    return 1
  end
end

local function copy_point(point)
  return {
    range_type = point.range_type,
    value = point.value,
    inclusive = point.inclusive,
  }
end

local function copy_ranges(ranges)
  local copy = {}
  for i, point in ipairs(ranges) do
    copy[i] = copy_point(point)
  end
  return copy
end

local function get_range_type(point)
  return point.range_type
end

---FIXME: there are several edge cases normalize is not accounting for which will cause issues [...]
---when combined with the other ranges functions. Such edge cases are related to ranges that are [...]
---so short that they are better described as `integral` or `non_integral` than `everything`. [...]
---There is also a good chance that the current combine and contains functions do not account [...]
---for similar edge cases, however I believe that once normalize is fixed they would be fixed as well [...]
---since they are intended to run on normalized ranges. The only downside is that at that point it is [...]
---required to normalize ranges after doing literally anything to them, which means all the other [...]
---ranges functions should just normalize their result before returning
local function normalize(ranges)
  local prev_type = get_range_type(ranges[1])
  local target_index = 2
  for i = 2, #ranges do
    local point = ranges[i]
    ranges[i] = nil
    local type = get_range_type(point)
    if type == prev_type then
      target_index = target_index - 1
    else
      ranges[target_index] = point
      prev_type = type
    end
    target_index = target_index + 1
  end
  return ranges
end

local function union_range_type(type_one, type_two)
  if type_one == type_two then return type_one end
  if type_one == range_type.nothing then return type_two end
  if type_two == range_type.nothing then return type_one end
  return range_type.everything
end

local function union_range(ranges, from, to)
  local i = 2
  local c = #ranges
  local prev_point = ranges[1]
  local prev_range_type
  while i <= c + 1 do
    local point = ranges[i]
    if compare_point(point, from) == -1 then
      -- the range to add starts before `point`
      prev_range_type = get_range_type(prev_point)
      local overlap_from
      if compare_point(prev_point, from) <= 0 then
        overlap_from = prev_point -- overwrite
      else
        overlap_from = copy_point(from) -- insert new
        table.insert(ranges, i, overlap_from)
        i = i + 1
        c = c + 1
      end
      overlap_from.range_type = union_range_type(get_range_type(prev_point), get_range_type(from))

      if compare_point(point, to) == 0 then
        -- the range to add already stops at the exact same point as `point`, so nothing needs to change
        return ranges
      elseif compare_point(point, to) == -1 then
        -- the range to add stops before `point`
        to.range_type = prev_range_type
        table.insert(ranges, i, to)
        return ranges
      end
    end
    prev_point = point
    i = i + 1
  end
  util.debug_abort("Impossible because the condition for the second return in the loop \z
    should always be true in the last iteration."
  )
end

local function combine_ranges(left_ranges, right_ranges, combine_type)
  local left_index = 2
  local left_count = #left_ranges
  local left_from = left_ranges[1]
  local right_index = 3
  local right_from = right_ranges[1]
  local right_to = right_ranges[2]
  while left_index <= left_count + 1 do
    local left_to = left_ranges[left_index]
    if compare_point(left_to, right_from) == -1 then
      -- the current right range starts before the current left range stops => overlap
      local prev_left_range_type = get_range_type(left_from)
      -- this logic ends up being much simpler than the `union_range` because the logic below
      -- ends up inserting `right_to` causing the next iteration's `left_from` to always start
      -- at `right_from`. If I understand correctly `right_from` doesn't even come before `left_from`
      -- ever, but both those cases are handled the same way
      left_from.range_type = combine_type(get_range_type(left_from), get_range_type(right_from))

      if compare_point(left_to, right_to) == 0 then
        -- the right range already stops at the exact same point as `left_to`, so nothing needs to change
      elseif compare_point(left_to, right_to) == -1 then
        -- the right range stops before `left_to`
        local new_point = copy_point(right_to)
        new_point.range_type = prev_left_range_type
        table.insert(left_ranges, left_index, new_point)
        left_count = left_count + 1
        left_to = new_point
      else
        goto skip_advance_right
      end

      if not right_to then
        return left_ranges
      end
      right_from = right_to
      right_to = right_ranges[right_index]
      right_index = right_index + 1
      ::skip_advance_right::
    end
    left_from = left_to
    left_index = left_index + 1
  end
  util.debug_abort("Impossible because the condition for the second return in the loop \z
    should always be true in the last iteration."
  )
end

local function union_ranges(left_ranges, right_ranges)
  return combine_ranges(left_ranges, right_ranges, union_range_type)
end

local function contains_range_type(base_type, other_type)
  return (({
    [range_type.everything] = function()
      return true
    end,
    [range_type.integral] = function()
      return other_type == range_type.integral or other_type == range_type.nothing
    end,
    [range_type.non_integral] = function()
      return other_type == range_type.non_integral or other_type == range_type.nothing
    end,
    [range_type.nothing] = function()
      return other_type == range_type.nothing
    end,
  })[base_type] or util.debug_abort("Unknown range_type '"..tostring(base_type).."'."))()
end

local function compare_ranges(left_ranges, right_ranges, comparator)
  local left_from = left_ranges[1]
  local left_to = left_ranges[2]
  local left_index = 3
  local right_from = right_ranges[1]
  local right_to = right_ranges[2]
  local right_index = 3
  while true do
    if not comparator(left_from, right_from) then
      return false
    end
    -- advance whichever side is behind the right
    -- or both if they are equal
    local diff = compare_point(left_to, right_to)
    if diff <= 0 then
      if not right_to then
        -- right_to is nil and diff <= 0 which means left_to is also nil
        -- which means we have reached the end
        return true
      end
      right_from = right_to
      right_to = right_ranges[right_index]
      right_index = right_index + 1
    end
    if diff >= 0 then
      left_from = left_to
      left_to = left_ranges[left_index]
      left_index = left_index + 1
    end
  end
end

local function contains_ranges(base_ranges, other_ranges)
  return compare_ranges(base_ranges, other_ranges, function(base_point, other_point)
    return contains_range_type(get_range_type(base_point), get_range_type(other_point))
  end)
end

local function ranges_equal(left_ranges, right_ranges)
  return compare_ranges(left_ranges, right_ranges, function(left_point, right_point)
    return get_range_type(left_point) == get_range_type(right_point)
  end)
end

local function intersect_range_type(left_type, right_type)
  if left_type == right_type then return left_type end
  if left_type == range_type.everything then return right_type end
  if right_type == range_type.everything then return left_type end
  return range_type.nothing
end

local function intersect_ranges(left_ranges, right_ranges)
  return combine_ranges(left_ranges, right_ranges, intersect_range_type)
end

local function exclude_range_type(left_type, right_type)
  if left_type == right_type or right_type == range_type.everything then return range_type.nothing end
  if right_type == range_type.nothing then return left_type end
  if left_type == range_type.everything then
    return right_type == range_type.integral and range_type.non_integral or range_type.integral
  end
  return left_type
end

local function exclude_ranges(left_ranges, right_ranges)
  return combine_ranges(left_ranges, right_ranges, exclude_range_type)
end

return {
  range_type = range_type,
  range_type_str_lut = range_type_str_lut,
  inclusive = inclusive,
  exclusive = exclusive,
  compare_point = compare_point,
  copy_point = copy_point,
  copy_ranges = copy_ranges,
  normalize = normalize,
  union_range_type = union_range_type,
  union_range = union_range,
  union_ranges = union_ranges,
  contains_range_type = contains_range_type,
  contains_ranges = contains_ranges,
  ranges_equal = ranges_equal,
  intersect_range_type = intersect_range_type,
  intersect_ranges = intersect_ranges,
  exclude_range_type = exclude_range_type,
  exclude_ranges = exclude_ranges,
}
