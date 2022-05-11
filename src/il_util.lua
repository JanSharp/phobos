
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
        range.integral = true
      end
    end
    return range
  end

  local function union_ranges(left_ranges, right_ranges)
    -- if one of them is nil the result will also be nil
    if not left_ranges or not right_ranges then return nil end
    local ranges = {}
    do -- put all ranges into one list ordered by `from`
      local left_index = 1
      local left = left_ranges[1]
      for _, right in ipairs(right_ranges) do
        while left and left.from <= right.from do
          ranges[#ranges+1] = util.shallow_copy(left)
          left_index = left_index + 1
          left = left_ranges[left_index]
        end
        ranges[#ranges+1] = util.shallow_copy(right)
      end
    end
    local result = {}
    do
      local current_result = normalize_integral(ranges[1])
      for i = 2, #ranges do
        local range = normalize_integral(ranges[i])
        -- first let's figure out if the current range is even overlapping or apart of the current_result
        if range.from <= current_result.to then
          -- there is still one case where these 2 ranges are actually not apart of each other
          -- this condition makes sure that is not the case
          -- TODO: there is a chance that current_result.to == range.from, but both are not inclusive [...]
          -- then the next range - next iteration - extends the now new current_result backwards by setting
          -- inclusive_from to true. [...]
          -- this would cause ranges to be touching each other retroactively which is invalid
          if range.from == current_result.to
            and range.inclusive_from or current_result.inclusive_to
          then
            -- alright, so we need to combine these 2
            -- but there is this case where the range could stop or even split the current_result range
            if not range.integral and current_result.integral then
              -- we need to cut the current_result short
              local actual_integral_to = current_result.to -- remember
              current_result.to = math.floor(range.from)
              -- but what if the 2 are equal to each other?
              if current_result.to == range.from then
                -- well it depends on if the current range is inclusive_from or not
                if range.inclusive_from then
                  -- now we need to push the current_result back by 1
                  current_result.to = range.from - 1
                  -- and now there is a chance that we just made current_result invalid
                  if current_result.to < current_result.from then
                    current_result = nil -- if so, drop it
                  end
                end
              end
              -- at this point current_result has been cut of or even dropped
              result[#result+1] = current_result -- works with nil
              -- the previous current_result might have reached past the current range
              if actual_integral_to > range.to then
                -- in that case we have to create a new integral range past the current range
                local new_from = math.ceil(range.to)
                if new_from == range.to and range.inclusive_to then
                  -- again, if they are equal and overlapping, adjust by 1
                  new_from = new_from + 1
                end
                -- that creates a potential of creating an invalid range, so don't do that
                if new_from > actual_integral_to then
                  local new_range = {
                    from = new_from,
                    to = actual_integral_to,
                    integral = true,
                    inclusive_from = true,
                    inclusive_to = true,
                  }
                  result[#result+1] = range -- with that we can add the current range
                  current_result = new_range -- and keep the new_range as the next current_result
                  -- TODO: this creates a potential of invalid overlapping ranges, because the current [...]
                  -- range has been added to the result list without checking if there are more ranges that
                  -- overlap with it. A problem for later
                  goto continue -- and we are done
                end
              end
              -- alright, didn't add a new range past the current range so just use the current range
              -- as the next current_result and move on
              current_result = range
              goto continue
            end
            -- ok, not splitting ranges, just overlapping or right next to each other
            -- check if we need to extend the current_result
            if current_result.to < range.to then
              -- range shoots past current_result, completely overwrite its range end
              current_result.to = range.to
              current_result.inclusive_to = range.inclusive_to
            elseif current_result.to == range.to and range.inclusive_to then
              -- stopping right on top of each other, but inclusive_to might still make it reach further
              current_result.inclusive_to = true
            end
            -- alright, extended, now move on to the next without adding anything to the result
            goto continue
          end
          -- not touching, just leave and let the code below handle it
        elseif range.integral and current_result.integral then
          -- integral ranges are special in that they are technically filled with gaps
          -- that means if there is exactly one gap between this one and the previous one
          -- they are still apart of each other
          if range.from - 1 == current_result.to then
            current_result.to = range.to -- extend the current_result
            goto continue -- and we are done
          end
        end
        -- if we get here the range is not apart of the current_result in any way
        result[#result+1] = current_result
        current_result = range
        ::continue::
      end
      -- we're done combining stuff, just add the last one and then we're truly done
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
