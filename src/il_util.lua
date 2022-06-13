
local util = require("util")

local nil_flag = 1
local boolean_flag = 2
local number_flag = 4
local string_flag = 8
local function_flag = 16
local table_flag = 32
local userdata_flag = 64
local thread_flag = 128

---@class ILTypeParams
---@field type_flags ILTypeFlags

---@param params ILTypeParams
local function new_type(params)
  return params
end

local range_type = {
  all_numbers = 0,
  integral = 1,
  non_integral = 2,
}

local function is_all_numbers(range)
  return range.range_type == range_type.all_numbers
end

local function is_integral(range)
  return range.range_type == range_type.integral
end

local function is_non_integral(range)
  return range.range_type == range_type.non_integral
end

local copy_identity
local copy_identities
local copy_class
local copy_type
local copy_types
do
  local function copy_list(list, copy_func)
    if not list then return end
    local result = {}
    for i, value in ipairs(list) do
      result[i] = copy_func(value)
    end
    return result
  end

  function copy_identity(identity)
    return {
      id = identity.id,
      type_flags = identity.type_flags,
    }
    -- TODO: extend this when deciding what data structures are in ILTypeIdentity
  end

  function copy_identities(identities)
    return copy_list(identities, copy_identity)
  end

  function copy_class(class)
    local result = {}
    if class.kvps then
      local kvps = {}
      result.kvps = kvps
      for i, kvp in ipairs(class.kvps) do
        kvps[i] = {
          key_type = copy_type(kvp.key_type),
          value_type = copy_type(kvp.value_type),
        }
      end
    end
    result.metatable = class.metatable and copy_class(class.metatable)
    return result
  end

  function copy_type(type)
    local result = new_type{
      type_flags = type.type_flags,
      number_ranges = util.copy(type.number_ranges),
      string_ranges = util.copy(type.string_ranges),
      string_values = util.optional_shallow_copy(type.string_values),
      boolean_value = type.boolean_value,
      function_prototypes = util.optional_shallow_copy(type.function_prototypes),
      light_userdata_prototypes = util.optional_shallow_copy(type.light_userdata_prototypes),
    }
    result.identities = copy_identities(type.identities)
    result.table_class = copy_class(type.table_class)
    result.userdata_class = copy_class(type.userdata_class)
  end

  function copy_types(types)
    return copy_list(types, copy_type)
  end
end

local identity_list_contains
local identity_list_equal
do
  local function contains_internal(left, right, get_value)
    local lut = {}
    for _, value in ipairs(left) do
      lut[get_value and get_value(value) or value] = true
    end
    for _, value in ipairs(right) do
      value = get_value and get_value(value) or value
      if not lut[value] then
        return false
      end
      lut[value] = nil
    end
    return true, lut
  end

  function identity_list_contains(left, right, get_value)
    if not left then return true end
    return (contains_internal(left, right, get_value))
  end

  function identity_list_equal(left, right, get_value)
    if not left then return not right end
    local result, lut = contains_internal(left, right, get_value)
    return result and not next(lut)
  end
end

local equals
do
  local function ranges_equal(left_ranges, right_ranges)
    if not left_ranges then return not right_ranges end
    local i = 1
    while true do
      local left = left_ranges[i]
      local right = right_ranges[i]
      if not left and not right then return true end
      if not left
        or not right
        or left.from ~= right.from
        or left.to ~= right.to
        or left.inclusive_from ~= right.inclusive_from
        or left.inclusive_to ~= right.inclusive_to
        or left.integral ~= right.integral
      then
        return false
      end
      i = i + 1
    end
  end

  -- NOTE: classes with key value pairs where multiple of their value types are equal are invalid [...]
  -- and will result in this compare function to potentially return false in cases where it shouldn't
  local function compare_class(left_class, right_class)
    if not left_class then return not right_class end
    if left_class.kvps then
      if not right_class.kvps then return false end
      if #left_class.kvps ~= #right_class.kvps then return false end
      local finished_right_index_lut = {}
      for _, left_kvp in ipairs(left_class.kvps) do
        for right_index, right_kvp in ipairs(right_class.kvps) do
          if not finished_right_index_lut[right_index] and equals(left_kvp.key_type, right_kvp.key_type) then
            if not equals(left_kvp.value_type, right_kvp.value_type) then
              return false
            end
            finished_right_index_lut[right_index] = true
            goto found_match
          end
        end
        do return false end
        ::found_match::
      end
    end
    if left_class.metatable then
      if not right_class.metatable then return false end
      return compare_class(left_class.metatable, right_class.metatable)
    end
    return true
  end

  ---@param left_type ILType
  ---@param right_type ILType
  function equals(left_type, right_type)
    local type_flags = left_type.type_flags
    if type_flags ~= right_type.type_flags then
      return false
    end
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value ~= right_type.boolean_value then
        return false
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      if not ranges_equal(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not ranges_equal(left_type.string_ranges, right_type.string_ranges) then
        return false
      end
      if not identity_list_equal(left_type.string_values, right_type.string_values) then
        return false
      end
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      if not identity_list_equal(left_type.function_prototypes, right_type.function_prototypes) then
        return false
      end
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      if not compare_class(left_type.table_class, right_type.table_class) then
        return false
      end
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      if not identity_list_equal(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      ) then
        return false
      end
      if not compare_class(left_type.userdata_class, right_type.userdata_class) then
        return false
      end
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end

    if not identity_list_equal(
      left_type.identities,
      right_type.identities,
      function(value) return value.id end
    ) then
      return false
    end

    return true
  end
end

local union
do
  local function get_types_to_combine(left_type, right_type, flag)
    local left_has_flag = bit32.band(left_type.type_flags, flag)
    local right_has_flag = bit32.band(right_type.type_flags, flag)
    if left_has_flag and right_has_flag then
      return nil, true
    end
    if left_has_flag then
      return left_type
    end
    if right_has_flag then
      return right_type
    end
  end

  local function shallow_list_union(left_list, right_list)
    -- if one of them is nil the result will also be nil
    if not left_list or not right_list then return nil end
    local lut = {}
    local result = {}
    for i, value in ipairs(left_list) do
      lut[value] = true
      result[i] = value
    end
    for _, value in ipairs(right_list) do
      if not lut[value] then
        result[#result+1] = value
      end
    end
    return result
  end

  local function normalize_integral(range)
    if range.from == range.to then
      util.debug_assert(range.inclusive_from and range.inclusive_to, "There is a range that contains \z
        zero values making it invalid. Use library functions to create and manipulate ranges."
      )
      if (range.from % 1) == 0 then
        if is_all_numbers(range) then
          range.range_type = range_type.integral
        end
      end
    end
    return range
  end

  ---does the `range_in_question` overlap at the `from`-end of the `base_range`
  local function range_overlaps_at_from(range_in_question, base_range)
    return base_range.to > range_in_question.from
      or (base_range.to == range_in_question.from
        and base_range.inclusive_to
        and range_in_question.inclusive_from
      )
  end

  ---does the `range_in_question` overlap at the `to`-end of the `base_range`
  local function range_overlaps_at_to(range_in_question, base_range)
    return range_overlaps_at_from(base_range, range_in_question)
  end

  ---do these ranges overlap in some way
  local function ranges_overlap(range_one, range_two)
    return range_overlaps_at_from(range_one, range_two) and range_overlaps_at_to(range_one, range_two)
  end

  ---expects `left_range` to come before `right_range`
  local function ranges_touch(left_range, right_range)
    return (left_range.to == right_range.from and (left_range.inclusive_to == not right_range.inclusive_from))
      or (is_integral(left_range) and is_integral(right_range) and left_range.to + 1 == right_range.from)
      or (is_non_integral(left_range) and is_non_integral(right_range) and left_range.to == right_range.from)
  end

  local function ranges_match(range_one, range_two)
    return range_one.range_type == range_two.range_type
  end

  ---modifies `to_extend`, `integral` must be the same on both ranges
  local function extend_matching_ranges(to_extend, to_merge)
    if to_merge.from < to_extend.from then
      to_extend.from = to_merge.from
      to_extend.inclusive_from = to_merge.inclusive_from
    elseif to_merge.from == to_extend.from and to_merge.inclusive_from then
      to_extend.inclusive_from = to_merge.inclusive_from
    end
    if to_merge.to > to_extend.to then
      to_extend.to = to_merge.to
      to_extend.inclusive_to = to_merge.inclusive_to
    elseif to_merge.to == to_extend.to and to_merge.inclusive_to then
      to_extend.inclusive_to = to_merge.inclusive_to
    end
  end

  ---returns `-1` if other_range starts earlier than base_range\
  ---returns `0` if other_range starts at the same point as the base_range\
  ---returns `1` if other_range starts later than base_range
  local function compare_ranges_start(base_range, other_range)
    if other_range.from < base_range.from then
      return -1
    end
    if other_range.from > base_range.from then
      return 1
    end
    if other_range.inclusive_from == base_range.inclusive_from then
      return 0
    end
    if other_range.inclusive_from then -- `and not base_range.inclusive_from` is implied/guaranteed
      return -1
    else
      return 1
    end
  end

  ---returns `-1` if other_range stops earlier than base_range\
  ---returns `0` if other_range stops at the same point as the base_range\
  ---returns `1` if other_range stops later than base_range
  local function compare_ranges_stop(base_range, other_range)
    if other_range.to < base_range.to then
      return -1
    end
    if other_range.to > base_range.to then
      return 1
    end
    if other_range.inclusive_to == base_range.inclusive_to then
      return 0
    end
    if other_range.inclusive_to then -- `and not base_range.inclusive_to` is implied/guaranteed
      return -1
    else
      return 1
    end
  end

  local function combine_ranges(left_ranges, right_ranges)
    local ranges = {}
    local count = 0
    do -- put all ranges into one list ordered by their staring point, earliest first
      local left_index = 1
      local left = left_ranges[1]
      for _, right in ipairs(right_ranges) do
        while left and compare_ranges_start(right, left) == -1 do
          count=count+1;ranges[count] = left
          left_index = left_index + 1
          left = left_ranges[left_index]
        end
        count=count+1;ranges[count] = right
      end
    end
    ranges.count = count
    return ranges
  end

  local function insert_range(ranges, range, start_index)
    local new_count = ranges.count + 1
    for i = start_index or 1, new_count do
      if i == new_count or compare_ranges_start(ranges[i], range) ~= -1 then
        table.insert(ranges, i, range)
        ranges.count = new_count
        return
      end
    end
    util.debug_abort("Impossible because the above loop loops until 1 past the count with a check in \z
      the loop if we reached said last index to then return out of this function."
    )
  end

  -- ---may modify both ranges and may even invalidate one of the 2 ranges
  -- ---NOTE: unused code, just as a reminder for how I wanted to handle this if I ever care to actually do it
  -- local function normalize_mismatching_touching_ranges(left_range, right_range)
  --   if is_integral(left_range) then
  --     if is_non_integral(right_range) then
  --       -- would have to create a new range between left and right
  --       -- said range would have to be all_numbers starting at the last number of the left
  --       -- range and stopping at just before the second number of the right range
  --       -- then it would have to shift both left and right range back and forwards accordingly
  --       -- potentially invalidating both of them
  --     else -- right_range is all_numbers
  --       left_range.to = left_range.to - 1
  --       right_range.inclusive_from = true
  --       if left_range.from > left_range.to then
  --         left_range.invalid = true
  --       end
  --     end
  --   elseif is_non_integral(left_range) then
  --     if is_integral(right_range) then
  --       -- same thing as left being integral and right being non integral, just flipped
  --     else -- right_range is all_numbers
  --       -- similar to integral ranges and all_number ranges, extend the all number range
  --       -- and shorten the non integral range potentially invalidating it
  --     end
  --   else -- left_range is all_numbers
  --     if is_integral(right_range) then
  --       right_range.from = right_range.from + 1
  --       left_range.inclusive_to = true
  --       if right_range.from > right_range.to then
  --         right_range.invalid = true
  --       end
  --     else -- right_range is non_integral
  --       -- similar to integral ranges aid all_number ranges, extend the all number range
  --       -- and shorten the non integral range potentially invalidating it
  --     end
  --   end
  -- end

  local function split_overlapping_ranges(left_range, right_range)
    local result = {}
    if left_range.from <= right_range.from then
      local left_not_overlapping_range
      if left_range.from ~= right_range.from
        or (left_range.inclusive_from and not right_range.inclusive_from)
      then
        -- not completely overlapping starting points
        left_not_overlapping_range = {
          range_type = left_range.range_type,
          from = left_range.from,
          to = right_range.from,
          inclusive_from = left_range.inclusive_from,
          inclusive_to = not right_range.inclusive_from,
        }
        if not is_all_numbers(left_range)
          and left_not_overlapping_range.to ~= (-1/0)
          and left_not_overlapping_range.inclusive_to ~= left_range.inclusive_to
        then
          left_not_overlapping_range.to = left_not_overlapping_range.to - 1
          if left_not_overlapping_range.to < left_not_overlapping_range.from then
            left_not_overlapping_range = nil
          end
        end
      end
      result.left_not_overlapping_range = left_not_overlapping_range
    end
    ---expects `left_range` to stop earlier than or at the same point as `right_range`
    local function get_not_overlapping_range_top_end(left_range, right_range)
      -- copy paste from above except that it's all flipped
      local not_overlapping_range
      if left_range.to >= right_range.to then
        if left_range.to ~= right_range.to
          or (not left_range.inclusive_to and right_range.inclusive_to)
        then
          -- not completely overlapping stopping points
          not_overlapping_range = {
            range_type = right_range.range_type,
            from = left_range.to,
            to = right_range.to,
            inclusive_from = not left_range.inclusive_from,
            inclusive_to = right_range.inclusive_from,
          }
          if not is_all_numbers(right_range)
            and not_overlapping_range.from ~= (1/0)
            and not_overlapping_range.inclusive_from ~= right_range.inclusive_from
          then
            not_overlapping_range.from = not_overlapping_range.from + 1
            if not_overlapping_range.to < not_overlapping_range.from then
              not_overlapping_range = nil
            end
          end
        end
      end
      return not_overlapping_range
    end
    local overlapping_range = {
      range_type = nil, -- unknown at this point in time
      from = right_range.from,
      inclusive_from = right_range.inclusive_from,
    }
    result.overlapping_range = overlapping_range
    if compare_ranges_stop(left_range, right_range) == -1 then
      overlapping_range.to = right_range.to
      overlapping_range.inclusive_to = right_range.inclusive_to
      result.left_not_overlapping_range_top_end = get_not_overlapping_range_top_end(right_range, left_range)
    else
      overlapping_range.to = left_range.to
      overlapping_range.inclusive_to = left_range.inclusive_to
      result.right_not_overlapping_range = get_not_overlapping_range_top_end(left_range, right_range)
    end
    return result
  end

  ---NOTE: this can totally generate touching ranges in many cases
  local function cut_mismatching_overlapping_ranges_short(left_range, right_range, ranges, current_index)
    local split_ranges = split_overlapping_ranges(left_range, right_range)
    if split_ranges.left_not_overlapping_range then
      left_range.to = split_ranges.left_not_overlapping_range.to
      left_range.inclusive_to = split_ranges.left_not_overlapping_range.inclusive_to
    else
      left_range.invalid = true
    end
    if split_ranges.left_not_overlapping_range_top_end then
      insert_range(ranges, split_ranges.left_not_overlapping_range_top_end, current_index + 1)
    elseif split_ranges.right_not_overlapping_range then
      insert_range(ranges, split_ranges.right_not_overlapping_range, current_index + 1)
    end
    local overlapping = split_ranges.overlapping_range
    overlapping.range_type = range_type.all_numbers
    return overlapping
    -- This is just here to make it obvious that any of the 6 possible mismatching combinations
    -- result in an overlapping range with the type all_numbers
    -- -- if is_integral(left_range) then
    -- --   if is_non_integral(right_range) then
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   else -- right_range is all_numbers
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   end
    -- -- elseif is_non_integral(left_range) then
    -- --   if is_integral(right_range) then
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   else -- right_range is all_numbers
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   end
    -- -- else -- left_range is all_numbers
    -- --   if is_integral(right_range) then
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   else -- right_range is non_integral
    -- --     overlapping.range_type = range_type.all_numbers
    -- --   end
    -- -- end
    -- -- return overlapping
  end

  ---checks if this range is a valid range on its own
  ---TODO: update for range_type and non_integral
  local function is_valid_range(range)
    if range.invalid then
      return false
    end
    if range.integral then
      if not (range.from == (-1/0) or ((range.from % 1) == 0 and range.inclusive_from))
        or not (range.to == (1/0) or ((range.to % 1) == 0 and range.inclusive_to))
      then
        return false
      end
    end
    return range.from < range.to
      or (range.from == range.to and range.inclusive_from and range.inclusive_to)
  end

  local function process_right_range(left_range, right_range, ranges, current_index)
    local are_overlapping = range_overlaps_at_from(left_range, right_range)
    local are_touching = ranges_touch(left_range, right_range)
    if not are_overlapping and not are_touching then return left_range end
    if are_touching then
      if ranges_match(left_range, right_range) then
        extend_matching_ranges(left_range, right_range)
        return left_range
      else
        -- there is no reason to normalize these touching ranges
        -- it complicates things soo much for quite literally no gain
        return right_range
      end
    end
    if ranges_match(left_range, right_range) then
      extend_matching_ranges(left_range, right_range)
      return left_range
    end
    local overlapping_range = cut_mismatching_overlapping_ranges_short(left_range, right_range, ranges, current_index)
    -- left_range might have been invalidated, handled in the calling function
    return overlapping_range
  end

  local function union_ranges(left_ranges, right_ranges)
    -- if one of them is nil the result will also be nil
    if not left_ranges or not right_ranges then return nil end
    local ranges = combine_ranges(util.copy(left_ranges), util.copy(right_ranges))
    local result = {}
    local current_result = ranges[1]
    local i = 1 -- actually starting at 2, see start of the loop
    while i <= ranges.count do
      i = i + 1
      local range = ranges[i]
      local new_current_result = process_right_range(current_result, range, ranges, i)
      if new_current_result ~= current_result then
        if not current_result.invalid then
          result[#result+1] = current_result
        end
        current_result = new_current_result
      end
    end
    if current_result and not current_result.invalid then
      result[#result+1] = current_result
    end
    return result
  end

  function union(left_type, right_type)
    local result = new_type{type_flags = bit32.bor(left_type.type_flags, right_type.type_flags)}
    local base, do_merge
    base, do_merge = get_types_to_combine(left_type, right_type, nil_flag)
    if do_merge then
    elseif base then
    end
    base, do_merge = get_types_to_combine(left_type, right_type, boolean_flag)
    if do_merge then
      if left_type.boolean_value == right_type.boolean_value then
        result.boolean_value = left_type.boolean_value
      else
        result.boolean_value = nil
      end
    elseif base then
      result.boolean_value = base.boolean_value
    end
    base, do_merge = get_types_to_combine(left_type, right_type, number_flag)
    if do_merge then
      result.number_ranges = union_ranges(left_type.number_ranges, right_type.number_ranges)
    elseif base then
      result.number_ranges = util.copy(base.number_ranges)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, string_flag)
    if do_merge then
      result.string_ranges = union_ranges(left_type.string_ranges, right_type.string_ranges)
      result.string_values = shallow_list_union(left_type.string_values, right_type.string_values)
    elseif base then
      result.string_ranges = util.copy(base.string_ranges)
      result.string_values = util.optional_shallow_copy(base.string_values)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, function_flag)
    if do_merge then
      result.function_prototypes = shallow_list_union(
        left_type.function_prototypes,
        right_type.function_prototypes
      )
    elseif base then
      result.function_prototypes = util.optional_shallow_copy(base.function_prototypes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, table_flag)
    if do_merge then
      -- TODO: class
    elseif base then
      result.table_class = copy_class(base.table_class)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, userdata_flag)
    if do_merge then
      result.light_userdata_prototypes = shallow_list_union(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      )
      -- TODO: class
    elseif base then
      result.light_userdata_prototypes = util.optional_shallow_copy(base.light_userdata_prototypes)
      result.userdata_class = copy_class(base.userdata_class)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, thread_flag)
    if do_merge then
    elseif base then
    end
    -- hmm I haven't thought about the combination of classes and identities yet
    -- great point for me to take a break

    -- TODO: identities
    -- if not left_list or not right_list then return nil end
    -- local lut = {}
    -- local result = {}
    -- for i, value in ipairs(left_list) do
    --   lut[value] = true
    --   result[i] = value
    -- end
    -- for _, value in ipairs(right_list) do
    --   if not lut[value] then
    --     result[#result+1] = value
    --   end
    -- end
  end
end

local contains
do
  local function contains_range(left, right)
    return left.from <= right.from
      and not (
        right.inclusive_from and not left.inclusive_from
          and right.from == left.from
      )
      and right.to <= left.to
      and not (
        right.inclusive_to and not left.inclusive_to
          and right.to == left.to
      )
      and not (left.integral and not right.integral)
  end

  local function contains_ranges(left_ranges, right_ranges)
    if not left_ranges then return true end
    local left_index = 1
    local current_left_range = left_ranges[left_index]
    for _, right_range in ipairs(right_ranges) do
      while current_left_range do
        if contains_range(current_left_range, right_range) then
          break
        end
        left_index = left_index + 1
        current_left_range = left_ranges[left_index]
        if not current_left_range then
          return false
        end
      end
    end
    return true
  end

  local function contains_class(left_class, right_class)
    -- TODO: instead of checking contains, use intersections. When not empty, check if
    -- the right value type is contained, if yes add the current intersection to a union.
    -- then check if the current union is equal to the right key_type
    -- and only if that is true then the current right kvp is contained
  end

  function contains(left_type, right_type)
    local type_flags = right_type.type_flags
    -- do the right flags contain flags that the left flags don't?
    if bit32.band(bit32.bnot(left_type.type_flags), type_flags) ~= 0 then
      return false
    end
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value ~= nil and left_type.boolean_value ~= right_type.boolean_value then
        return false
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      if not contains_ranges(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not contains_ranges(left_type.string_ranges, right_type.string_ranges) then
        return false
      end
      if not identity_list_contains(left_type.string_values, right_type.string_values) then
        return false
      end
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      if not identity_list_contains(left_type.function_prototypes, right_type.function_prototypes) then
        return false
      end
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      if not contains_class(left_type.table_class, right_type.table_class) then
        return false
      end
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      if not identity_list_contains(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      ) then
        return false
      end
      if not contains_class(left_type.userdata_class, right_type.userdata_class) then
        return false
      end
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end

    if not identity_list_contains(
      left_type.identities,
      right_type.identities,
      function(value) return value.id end
    ) then
      return false
    end

    return true
  end
end

-- TODO: finish union
-- TODO: intersect
-- TODO: finish contains
-- TODO: exclude?
-- TODO: indexing
-- TODO: range utilities

return {
  nil_flag = nil_flag,
  boolean_flag = boolean_flag,
  number_flag = number_flag,
  string_flag = string_flag,
  function_flag = function_flag,
  table_flag = table_flag,
  userdata_flag = userdata_flag,
  thread_flag = thread_flag,
  new_type = new_type,
  copy_identity = copy_identity,
  copy_identities = copy_identities,
  copy_class = copy_class,
  copy_type = copy_type,
  copy_types = copy_types,
  equals = equals,
  union = union,
  contains = contains,
}
