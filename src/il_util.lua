
local util = require("util")
local number_ranges = require("number_ranges")

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
      number_ranges = number_ranges.copy_ranges(type.number_ranges),
      string_ranges = number_ranges.copy_ranges(type.string_ranges),
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
