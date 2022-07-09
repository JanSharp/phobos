
local util = require("util")
local number_ranges = require("number_ranges")
local error_code_util = require("error_code_util")

local nil_flag = 1
local boolean_flag = 2
local number_flag = 4
local string_flag = 8
local function_flag = 16
local table_flag = 32
local userdata_flag = 64
local thread_flag = 128
local every_flag = 255

---@class ILTypeParams
---@field type_flags ILTypeFlags
---@field inferred_flags ILTypeFlags

---@param params ILTypeParams
---@return ILType
local function new_type(params)
  params.type_flags = params.type_flags or 0
  params.inferred_flags = params.inferred_flags or 0
  return params--[[@as ILType]]
end

local copy_identity
local copy_identities
local copy_class
local copy_classes
local copy_type
local copy_types
do
  ---@generic T : table?
  ---@param list T
  ---@return T
  local function copy_list(list, copy_func)
    if not list then return nil end
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

  ---@generic T : ILClass[]?
  ---@param classes T
  ---@return T
  function copy_classes(classes)
    return copy_list(classes, copy_class)
  end

  function copy_type(type)
    local result = new_type{
      type_flags = type.type_flags,
      inferred_flags = type.inferred_flags,
      number_ranges = type.number_ranges and number_ranges.copy_ranges(type.number_ranges),
      string_ranges = type.string_ranges and number_ranges.copy_ranges(type.string_ranges),
      string_values = util.optional_shallow_copy(type.string_values),
      boolean_value = type.boolean_value,
      function_prototypes = util.optional_shallow_copy(type.function_prototypes),
      light_userdata_prototypes = util.optional_shallow_copy(type.light_userdata_prototypes),
    }
    result.identities = copy_identities(type.identities)
    result.table_classes = copy_classes(type.table_classes)
    result.userdata_classes = copy_classes(type.userdata_classes)
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
    return result and not next(lut--[[@as table]])
  end
end

local equals

-- NOTE: classes with key value pairs where multiple of their value types are equal are invalid [...]
-- and will result in this compare function to potentially return false in cases where it shouldn't
local function class_equals(left_class, right_class)
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
    return class_equals(left_class.metatable, right_class.metatable)
  end
  return true
end

local function classes_equal(left_classes, right_classes)
  if not left_classes then return not right_classes end
  if #left_classes ~= #right_classes then return false end
  local finished_right_index_lut = {}
  for _, left_class in ipairs(left_classes) do
    for right_index, right_class in ipairs(right_classes) do
      if not finished_right_index_lut[right_index] and class_equals(left_class, right_class) then
        finished_right_index_lut[right_index] = true
        goto found_match
      end
    end
    do return false end
    ::found_match::
  end
  return true
end

do
  ---does not care about `inferred_flags` nor `ILClass.inferred`
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
      if not number_ranges.ranges_equal(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not number_ranges.ranges_equal(left_type.string_ranges, right_type.string_ranges) then
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
      if not classes_equal(left_type.table_classes, right_type.table_classes) then
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
      if not classes_equal(left_type.userdata_classes, right_type.userdata_classes) then
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

  ---@param left_classes ILClass[]?
  ---@param right_classes ILClass[]?
  local function union_classes(left_classes, right_classes)
    -- if one of them is nil the result will also be nil
    if not left_classes or not right_classes then return nil end
    local result = copy_classes(left_classes)
    local visited_left_index_lut = {}
    for _, right_class in ipairs(right_classes) do
      for left_index = 1, #left_classes do
        if not visited_left_index_lut[left_index] and class_equals(left_classes[left_index], right_class) then
          visited_left_index_lut[left_index] = true
          goto found_match
        end
      end
      result[#result+1] = copy_class(right_class)
      ::found_match::
    end
    return result
  end

  -- NOTE: very similar to shallow_list_union, just id comparison is different
  local function identities_union(left_identities, right_identities)
    -- if one of them is nil the result will also be nil
    if not left_identities or not right_identities then return nil end
    local lut = {}
    local result = {}
    for i, id in ipairs(left_identities) do
      lut[id.id] = true
      result[i] = id
    end
    for _, id in ipairs(right_identities) do
      -- TODO: if it finds the id in the lut it should probably create a union of the respective instance data
      if not lut[id.id] then
        result[#result+1] = id
      end
    end
    return result
  end

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  function union(left_type, right_type)
    local result = new_type{
      type_flags = bit32.bor(left_type.type_flags, right_type.type_flags),
      inferred_flags = bit32.bor(left_type.inferred_flags, right_type.inferred_flags),
    }
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
      result.number_ranges = number_ranges.union_ranges(left_type.number_ranges, right_type.number_ranges)
    elseif base then
      result.number_ranges = number_ranges.copy_ranges(base.number_ranges)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, string_flag)
    if do_merge then
      result.string_ranges = number_ranges.union_ranges(left_type.string_ranges, right_type.string_ranges)
      result.string_values = shallow_list_union(left_type.string_values, right_type.string_values)
    elseif base then
      result.string_ranges = number_ranges.copy_ranges(base.string_ranges)
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
      result.table_classes = union_classes(left_type.table_classes, right_type.table_classes)
    elseif base then
      result.table_classes = copy_classes(base.table_classes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, userdata_flag)
    if do_merge then
      result.light_userdata_prototypes = shallow_list_union(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      )
      result.userdata_classes = union_classes(left_type.userdata_classes, right_type.userdata_classes)
    elseif base then
      result.light_userdata_prototypes = util.optional_shallow_copy(base.light_userdata_prototypes)
      result.userdata_classes = copy_classes(base.userdata_classes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, thread_flag)
    if do_merge then
    elseif base then
    end

    result.identities = identities_union(left_type.identities, right_type.identities)

    return result
  end
end

local intersect
do
  local function shallow_list_intersect(left_list, right_list)
    if not left_list then
      if not right_list then
        return nil
      else
        return util.shallow_copy(right_list)
      end
    elseif not right_list then
      return util.shallow_copy(left_list)
    else
      local value_lut = {}
      for _, value in ipairs(left_list) do
        value_lut[value] = true
      end
      local string_values = {}
      for _, value in ipairs(right_list) do
        if value_lut[value] then
          string_values[#string_values+1] = value
        end
      end
      return string_values
    end
  end

  local function ranges_intersect(left_ranges, right_ranges)
    if not left_ranges then
      if not right_ranges then
        return nil
      end
      return number_ranges.copy_ranges(right_ranges)
    elseif not right_ranges then
      return number_ranges.copy_ranges(left_ranges)
    end
    return number_ranges.intersect_ranges(left_ranges, right_ranges)
  end

  local function classes_intersect(left_classes, right_classes)
    if not left_classes then
      if not right_classes then
        return nil
      else
        return copy_classes(right_classes)
      end
    elseif not right_classes then
      return copy_classes(left_classes)
    end
    local finished_right_index_lut = {}
    local result = {}
    for _, left_class in ipairs(left_classes) do
      for right_index, right_class in ipairs(right_classes) do
        if not finished_right_index_lut[right_index] and class_equals(left_class, right_class) then
          finished_right_index_lut[right_index] = true
          result[#result+1] = copy_class(left_class)
          break
        end
      end
    end
    return result
  end

  -- NOTE: very similar to shallow_list_union, just copying and id comparison is different
  local function identities_intersect(left_identities, right_identities)
    if not left_identities then
      if not right_identities then
        return nil
      else
        return copy_identities(right_identities)
      end
    elseif not right_identities then
      return copy_identities(left_identities)
    else
      local id_lut = {}
      for _, id in ipairs(left_identities) do
        id_lut[id.id] = true
      end
      local result = {}
      for _, id in ipairs(right_identities) do
        if id_lut[id.id] then
          result[#result+1] = id
        end
      end
      return result
    end
  end

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  function intersect(left_type, right_type)
    local result = new_type{
      type_flags = bit32.band(left_type.type_flags, right_type.type_flags),
      inferred_flags = bit32.band(left_type.inferred_flags, right_type.inferred_flags),
    }
    local type_flags = result.type_flags
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value == right_type.boolean_value then
        result.boolean_value = left_type.boolean_value
      elseif left_type.boolean_value == nil then
        result.boolean_value = right_type.boolean_value
      elseif right_type.boolean_value == nil then
        result.boolean_value = left_type.boolean_value
      else
        result.type_flags = bit32.bxor(result.type_flags, boolean_flag)
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      result.number_ranges = ranges_intersect(left_type.number_ranges, right_type.number_ranges)
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      result.string_ranges = ranges_intersect(left_type.string_ranges, right_type.string_ranges)
      result.string_values = shallow_list_intersect(left_type.string_values, right_type.string_values)
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      result.function_prototypes = shallow_list_intersect(
        left_type.function_prototypes,
        right_type.function_prototypes
      )
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      result.table_classes = classes_intersect(left_type.table_classes, right_type.table_classes)
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      result.light_userdata_prototypes = shallow_list_intersect(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      )
      result.userdata_classes = classes_intersect(left_type.userdata_classes, right_type.userdata_classes)
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end
    result.identities = identities_intersect(left_type.identities, right_type.identities)
    return result
  end
end

local contains
do
  local function contains_classes(left_classes, right_classes)
    if not right_classes then return not left_classes end
    if #left_classes < #right_classes then return false end
    local finished_left_index_lut = {}
    for _, right_class in ipairs(right_classes) do
      for left_index, left_class in ipairs(left_classes) do
        if not finished_left_index_lut[left_index] and class_equals(left_class, right_class) then
          finished_left_index_lut[left_index] = true
          goto found_match
        end
      end
      do return false end
      ::found_match::
    end
    return true
  end

  ---does not care about `inferred_flags` nor `ILClass.inferred`
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
      if not number_ranges.contains_ranges(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not number_ranges.contains_ranges(left_type.string_ranges, right_type.string_ranges) then
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
      if not contains_classes(left_type.table_classes, right_type.table_classes) then
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
      if not contains_classes(left_type.userdata_classes, right_type.userdata_classes) then
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

local exclude
do
  ---@generic T
  ---@param base_list T[]?
  ---@param other_list T[]?
  ---@return T[]?
  local function list_exclude(base_list, other_list)
    if not other_list then return nil end
    if not base_list then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local id_lut = {}
    for _, value in ipairs(other_list) do
      id_lut[value] = true
    end
    local result = {}
    for _, value in ipairs(base_list) do
      if not id_lut[value] then
        result[#result+1] = value
      end
    end
    return result
  end

  ---@param base_identities ILTypeIdentity[]?
  ---@param other_identities ILTypeIdentity[]?
  local function identity_list_exclude(base_identities, other_identities)
    if not other_identities then return nil end
    if not base_identities then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local id_lut = {}
    for _, id in ipairs(other_identities) do
      id_lut[id.id] = true
    end
    local result = {}
    for _, id in ipairs(base_identities) do
      if not id_lut[id.id] then
        result[#result+1] = id
      end
    end
    return result
  end

  ---@param base_classes ILClass[]?
  ---@param other_classes ILClass[]?
  local function exclude_classes(base_classes, other_classes)
    if not other_classes then return nil end
    if not base_classes then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local result = {}
    -- every left side that isn't found on the right side needs to be kept
    local visited_other_index_lut = {}
    for _, base_class in ipairs(base_classes) do
      for other_index = 1, #other_classes do
        if not visited_other_index_lut[other_index] and class_equals(base_class, other_classes[other_index]) then
          visited_other_index_lut[other_index] = true
          goto found_match
        end
      end
      result[#result+1] = copy_class(base_class)
      ::found_match::
    end
    return result
  end

  local everything_ranges = {number_ranges.inclusive(-1/0), number_ranges.range_type.everything}

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  ---@param base_type ILType
  ---@param other_type ILType
  ---@return ILType
  function exclude(base_type, other_type)
    -- TODO: how to handle excluding an inferred type from a non inferred type?
    local result = new_type{type_flags = base_type.type_flags, inferred_flags = base_type.inferred_flags}
    local type_flags_to_check = bit32.band(base_type.type_flags, other_type.type_flags)
    if bit32.band(type_flags_to_check, nil_flag) ~= 0 then
      result.type_flags = result.type_flags - nil_flag
    end
    if bit32.band(type_flags_to_check, boolean_flag) ~= 0 then
      if other_type.boolean_value == nil or base_type.boolean_value == other_type.boolean_value then
        result.type_flags = result.type_flags - boolean_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(boolean_flag))
      else
        result.boolean_value = base_type.boolean_value
      end
    end
    if bit32.band(type_flags_to_check, number_flag) ~= 0 then
      local base_ranges = base_type.number_ranges or everything_ranges
      local other_ranges = base_type.number_ranges or everything_ranges
      local result_number_ranges = number_ranges.exclude_ranges(base_ranges, other_ranges)
      if number_ranges.is_empty(result_number_ranges) then
        result.type_flags = result.type_flags - number_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(number_flag))
      else
        result.number_ranges = result_number_ranges
      end
    end
    if bit32.band(type_flags_to_check, string_flag) ~= 0 then
      local base_ranges = base_type.string_ranges or everything_ranges
      local other_ranges = base_type.string_ranges or everything_ranges
      local string_ranges = number_ranges.exclude_ranges(base_ranges, other_ranges)
      local string_values = list_exclude(base_type.string_values, other_type.string_values)
      if number_ranges.is_empty(string_ranges)
        and string_values and not string_values[1]
      then
        result.type_flags = result.type_flags - string_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(string_flag))
      else
        result.string_ranges = string_ranges
        result.string_values = string_values
      end
    end
    if bit32.band(type_flags_to_check, function_flag) ~= 0 then
      local function_prototypes = list_exclude(base_type.function_prototypes, other_type.function_prototypes)
      if function_prototypes and not function_prototypes[1] then
        result.type_flags = result.type_flags - function_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(function_flag))
      else
        result.function_prototypes = function_prototypes
      end
    end
    if bit32.band(type_flags_to_check, table_flag) ~= 0 then
      local table_classes = exclude_classes(base_type.table_classes, other_type.table_classes)
      if table_classes and not table_classes[1] then
        result.type_flags = result.type_flags - table_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(table_flag))
      else
        result.table_classes = table_classes
      end
    end
    if bit32.band(type_flags_to_check, userdata_flag) ~= 0 then
      local userdata_classes = exclude_classes(base_type.userdata_classes, other_type.userdata_classes)
      local light_userdata_prototypes = list_exclude(
        base_type.light_userdata_prototypes,
        other_type.light_userdata_prototypes
      )
      if userdata_classes and not userdata_classes[1]
        and light_userdata_prototypes and not light_userdata_prototypes[1]
      then
        result.type_flags = result.type_flags - userdata_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(userdata_flag))
      else
        result.userdata_classes = userdata_classes
        result.light_userdata_prototypes = light_userdata_prototypes
      end
    end
    if bit32.band(type_flags_to_check, thread_flag) ~= 0 then
      result.type_flags = result.type_flags - thread_flag
      result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(thread_flag))
    end
    result.identities = identity_list_exclude(base_type.identities, other_type.identities)
    return result
  end
end

local function has_all_flags(type_flags, other_flags)
  return bit32.band(type_flags, other_flags) == other_flags
end

local function has_any_flags(type_flags, other_flags)
  return bit32.band(type_flags, other_flags) ~= 0
end

-- TODO: range utilities

local type_indexing
local class_indexing

do
  local __index_key_type = new_type{
    type_flags = string_flag,
    string_ranges = {number_ranges.inclusive(-1/0)},
    string_values = {"__index"},
  }

  function class_indexing(class, index_type, do_rawget)
    local result_type = new_type{type_flags = 0}
    if class.kvps then
      for _, kvp in ipairs(class.kvps) do
        local overlap_key_type = intersect(kvp.key_type, index_type)
        if overlap_key_type.type_flags ~= 0 then
          result_type = union(result_type, overlap_key_type)
          result_type = union(result_type, kvp.value_type)
        end
      end
    end
    if not equals(result_type, index_type) then
      if not do_rawget and class.metatable then
        local __index_value_type = class_indexing(class.metatable, __index_key_type, true)
        local value_type_flags = __index_value_type.type_flags
        if has_all_flags(value_type_flags, nil_flag) then
          result_type = union(result_type, new_type{type_flags = nil_flag})
        end
        if has_all_flags(value_type_flags, table_flag) then
          result_type = union(result_type, type_indexing(__index_value_type, index_type))
        end
        if has_all_flags(value_type_flags, function_flag) then
          util.debug_print("-- TODO: validate `__index` function signatures and use function return types.")
          -- TODO: this function call could modify the entire current state which must be tracked somehow
        end
        if has_any_flags(value_type_flags, bit32.bnot(nil_flag + table_flag + function_flag)) then
          util.debug_print("-- TODO: probably warn about invalid `__index` value type.")
        end
      else
        result_type = union(result_type, new_type{type_flags = nil_flag})
      end
    end
    return result_type
  end

  function type_indexing(base_type, index_type, do_rawget)
    local err
    do
      local all_invalid_flags = nil_flag + boolean_flag + number_flag + function_flag + thread_flag
      local invalid_flags = bit32.band(base_type.type_flags, all_invalid_flags)
      if invalid_flags ~= 0 then
        err = error_code_util.new_error_code{
          error_code = error_code_util.codes.ts_invalid_index_base_type,
          message_args = {string.format("%x", invalid_flags)}, -- TODO: format flags as a meaningful string
        }
      end
    end
    local result_type = new_type{type_flags = 0}
    if bit32.band(base_type.type_flags, string_flag) then
      util.debug_print("-- TODO: add inbuilt string library function(s) to result type.")
    end
    if bit32.band(base_type.type_flags, table_flag) ~= 0 then
      if not base_type.table_classes then
        return new_type{type_flags = every_flag}, err
      end
      result_type = union(result_type, class_indexing(base_type.table_classes, index_type, do_rawget))
    end
    if bit32.band(base_type.type_flags, userdata_flag) ~= 0 then
      -- TODO: how to detect light userdata? indexing into light userdata is an error to my knowledge
      if not base_type.userdata_classes then
        return new_type{type_flags = every_flag}, err
      end
      result_type = union(result_type, class_indexing(base_type.userdata_classes, index_type, do_rawget))
    end
    if result_type.type_flags == 0 then -- default to nil, because that's how indexing works
      result_type.type_flags = nil_flag
    end
    return result_type, err
  end
end

return {
  nil_flag = nil_flag,
  boolean_flag = boolean_flag,
  number_flag = number_flag,
  string_flag = string_flag,
  function_flag = function_flag,
  table_flag = table_flag,
  userdata_flag = userdata_flag,
  thread_flag = thread_flag,
  every_flag = every_flag,
  new_type = new_type,
  copy_identity = copy_identity,
  copy_identities = copy_identities,
  copy_class = copy_class,
  copy_classes = copy_classes,
  copy_type = copy_type,
  copy_types = copy_types,
  equals = equals,
  union = union,
  intersect = intersect,
  contains = contains,
  exclude = exclude,
  has_all_flags = has_all_flags,
  has_any_flags = has_any_flags,
  class_indexing = class_indexing,
  type_indexing = type_indexing,
}
