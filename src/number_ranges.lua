
local util = require("util")

---@alias ILRangePointType
---| '0' @ nothing
---| '1' @ everything
---| '2' @ integral
---| '3' @ non_integral

---the first point in a ranges array must always exist and must be (-1/0) inclusive
---@class ILRangePoint
---@field range_type ILRangePointType
---@field value number
---@field inclusive boolean

local range_type = {
  nothing = 0,
  everything = 1,
  integral = 2,
  non_integral = 3,
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

local function get_range_type(point)
  return point.range_type
end

local function union_range_type(point_one, point_two)
  if not point_one then return get_range_type(point_two) end
  if not point_two then return point_one.range_type end
  if point_one.range_type == point_two.range_type then return point_one.range_type end
  if point_one.range_type == range_type.nothing then return point_two.range_type end
  if point_two.range_type == range_type.nothing then return point_one.range_type end
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
      overlap_from.range_type = union_range_type(prev_point, from)

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

local function union_ranges(left_ranges, right_ranges)
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
      left_from.range_type = union_range_type(left_from, right_from)

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

return {
  range_type = range_type,
  inclusive = inclusive,
  exclusive = exclusive,
  union_range = union_range,
  union_ranges = union_ranges,
}
