
---cSpell:ignore userdata, upval, upvals, nups, bytecode, metatable

local pretty_print = require("pretty_print").pretty_print
local util = require("util")

-- deep compare compares the contents of 2 values

-- tables are compared by identity,
-- if not equal then by their contents including iteration order

-- functions are compared by identity,
-- if not equal then by bytecode and all their upvals

-- so technically speaking light userdata is a Lua value that contains just a raw pointer
-- the equality for light userdata is determined by said raw pointer pointing to the same address
-- so technically speaking light userdata isn't a reference type in Lua itself, but since its
-- value is just a pointer it behaves just like a reference type to a value outside of Lua
-- TL;DR: light userdata behaves just like full userdata for our use case of comparing identity
local reference_type_lut = util.invert{"table", "function", "thread", "userdata"}

local do_not_compare_flag = {"do_not_compare_flag"}

local custom_comparators_lut = setmetatable({}, {__mode = "k"})
local custom_comparators_allow_nil = setmetatable({}, {__mode = "k"})

---@param comparator table<any, boolean>|fun(other:any, other_is_left:boolean):boolean, string, any @
---If it is a table, all keys are considered to be possible correct values on the other side.
---If any given value does not exist in this given table by directly indexing it, a deep compare will
---be performed on every possible value and it only fails if all given values do not match.\
---\
---If it is a function it is given the other value, plus a flag telling you if the other value is
---the left side of what is being compared, just in case you need that information.\
---The function should return a boolean indicating wether the value is correct or not.\
---If `false` then the function may return a second return value, a string, as a description of the
---difference, plus an optional third return value being any additional data which will be stored
---on the created diff as is.
---@param allow_nil boolean @ only used if comparator is a lookup table
local function register_custom_comparator(comparator, allow_nil)
  custom_comparators_lut[comparator] = true
  custom_comparators_allow_nil[comparator] = allow_nil or nil
  return comparator
end

local deep_compare
local difference_type = {
  value_type = 1, -- type of left and right are different
  c_function = 2, -- left or right are a c function while the other is either a non-c function or a different c function
  function_bytecode = 3, -- left and right are functions with differing bytecode
  primitive_value = 4, -- left and right are the same type, may only be a string, boolean or number but have different values
  thread = 5, -- left and right are threads that are not equal to each other
  userdata = 6, -- left and right are userdata that are not equal to each other
  size = 7, -- left and right are tables of different sizes, but up to the point where one ends they are equal
  identity_mismatch = 8, -- a reference value was visited before, but a second time they used different identities
  custom_comparator_func = 9, -- a custom comparator function deems a value incorrect
  custom_comparator_table = 10, -- a custom comparator table did not contain the other value
}
do
  local visited
  local reference_value_locations
  local compare_tables
  local difference
  local _compare_iteration_order

  local function add_reference_value_location(value, location)
    local location_list = reference_value_locations[value]
    if not location_list then
      location_list = {}
      reference_value_locations[value] = location_list
    end
    location_list[#location_list+1] = location
  end

  local function create_difference(diff_type, left, right, location)
    difference = {
      type = diff_type,
      location = location,
      left = left,
      left_ref_locations = reference_value_locations[left],
      right = right,
      right_ref_locations = reference_value_locations[right],
    }
  end

  local compare_values

  ---handling `visited` is not this function's job
  local function use_custom_comparator(comparator, other, other_is_left, location)
    if type(comparator) == "table" then
      if other == nil then
        if custom_comparators_allow_nil[comparator] then
          return true
        end
        difference = {
          type = difference_type.custom_comparator_table,
          location = location,
          comparator = comparator,
          other = other,
          other_ref_locations = reference_value_locations[other],
          other_is_left = other_is_left,
        }
        return false
      end
      if comparator[other] then
        return true
      end
      local differences = {}
      for _, value_to_compare in ipairs(comparator) do
        local old_visited = util.shallow_copy(visited)
        local result
        if other_is_left then
          result = compare_values(other, value_to_compare, location)
        else
          result = compare_values(value_to_compare, other, location)
        end
        if result then
          return true
        end
        differences[#differences+1] = difference
        difference = nil
        visited = old_visited
      end
      difference = {
        type = difference_type.custom_comparator_table,
        location = location,
        comparator = comparator,
        other = other,
        other_ref_locations = reference_value_locations[other],
        other_is_left = other_is_left,
        inner_differences = differences,
      }
      return false
    elseif type(comparator) == "function" then
      local success, message, data = comparator(other, other_is_left)
      if not success then
        difference = {
          type = difference_type.custom_comparator_func,
          location = location,
          comparator = comparator,
          other = other,
          other_ref_locations = reference_value_locations[other],
          other_is_left = other_is_left,
          message = message,
          data = data,
        }
        return false
      end
      return true
    else
      error("Custom Comparators can only be tables or functions")
    end
  end

  function compare_values(left, right, location)
    -- one of them is flagged as "don't compare these", so don't
    if left == do_not_compare_flag or right == do_not_compare_flag then
      return true
    end

    -- check if it has already been visited
    if visited[left] ~= nil or visited[right] ~= nil then
      if visited[left] == nil or visited[right] == nil
        or visited[left] ~= right
        -- or visited[right] ~= left
        -- if `visited[left] == right` then `visited[right] == left` is also true
      then
        create_difference(difference_type.identity_mismatch, left, right, location)
        return false
      end
      return true
    end

    -- check for custom comparators and use those if present
    if custom_comparators_lut[left] then
      if custom_comparators_lut[right] then
        error("Comparing 2 custom comparators is not supported")
      end
      local result = use_custom_comparator(left, right, false, location)
      -- comparing identity with non reference type values doesn't make sense
      -- besides it would very most likely break identity comparison
      if reference_type_lut[type(right)] then
        add_reference_value_location(left, location)
        add_reference_value_location(right, location)
        visited[left] = right
        visited[right] = left
      end
      return result
    end
    if custom_comparators_lut[right] then
      local result = use_custom_comparator(right, left, true, location)
      -- same here, see previous comment
      if reference_type_lut[type(left)] then
        add_reference_value_location(left, location)
        add_reference_value_location(right, location)
        visited[left] = right
        visited[right] = left
      end
      return result
    end

    -- compare nil, boolean, string, number (including NAN)
    if left == right or (left ~= left and right ~= right) then
      return true
    end
    local left_type = type(left)
    local right_type = type(right)
    if left_type ~= right_type then
      create_difference(difference_type.value_type, left, right, location)
      return false
    end

    -- after type check, `left` and `right` can't be nil anymore
    visited[left] = right
    visited[right] = left
    if reference_type_lut[left_type] then
      add_reference_value_location(left, location)
      add_reference_value_location(right, location)
    end

    if left_type == "thread" then
      create_difference(difference_type.thread, left, right, location)
      return false
    elseif left_type == "userdata" then
      create_difference(difference_type.userdata, left, right, location)
      return false
    elseif left_type == "function" then
      local left_info = debug.getinfo(left, "Su")
      local right_info = debug.getinfo(left, "S")
      if left_info.what == "C" or right_info.what == "C" then
        -- equality was already compared at the start, they are not equal
        -- or one isn't a c function
        create_difference(difference_type.c_function, left, right, location)
        return false
      end
      if string.dump(left) ~= string.dump(right) then
        create_difference(difference_type.function_bytecode, left, right, location)
        return false
      end
      -- compare upvals
      for i = 1, left_info.nups do
        local name, left_value = debug.getupvalue(left, i)
        local _, right_value = debug.getupvalue(right, i)
        if not compare_values(left_value, right_value, location.."[upval #"..i.." ("..name..")]") then
          return false
        end
      end
      return true
    elseif left_type == "table" then
      return compare_tables(left, right, location)
    end

    create_difference(difference_type.primitive_value, left, right, location)
    return false
  end

  function compare_tables(left, right, location)
    if _compare_iteration_order then
      local left_key, left_value = next(left)
      local right_key, right_value = next(right)
      local kvp_num = 0
      while left_key ~= nil do
        kvp_num = kvp_num + 1

        local key_location = location.."[key #"..kvp_num.."]"
        if right_key == nil then
          -- TODO: add more info about table sizes
          -- TODO: add support for do_not_compare
          create_difference(difference_type.size, left, right, key_location)
          return false
        end
        if not compare_values(left_key, right_key, key_location) then
          return false
        end

        local value_location = location.."["..pretty_print(left_key).." (value #"..kvp_num..")]"
        if not compare_values(left_value, right_value, value_location) then
          return false
        end

        left_key, left_value = next(left, left_key)
        right_key, right_value = next(right, right_key)
      end
      while right_key == do_not_compare_flag do
        right_key = next(right, right_key)
      end
      if right_key ~= nil then
        -- TODO: add more info about table sizes
        create_difference(difference_type.size, left, right, location)
        return false
      end
    else
      local done = {}
      for k, v in pairs(left) do
        done[k] = true
        local r_v = right[k]
        if not compare_values(v, r_v, location.."["..pretty_print(k).."]") then
          return false
        end
      end
      for k, v in pairs(right) do
        if not done[k] then
          if not compare_values(nil, v, location.."["..pretty_print(k).."]") then
            return false
          end
          -- compare_values can actually return true even though `v` is never `nil`,
          -- because there might be custom comparators or `do_not_compare_flag`s
        end
      end
    end

    local left_meta = debug.getmetatable(left)
    local right_meta = debug.getmetatable(right)
    if left_meta ~= nil or right_meta ~= nil then
      assert(type(left_meta) == "table", "Unexpected metatable type '"..type(left_meta).."'")
      assert(type(right_meta) == "table", "Unexpected metatable type '"..type(right_meta).."'")
      local result = compare_values(left_meta, right_meta, location.."[metatable]")
      return result
    end

    return true
  end

  function deep_compare(left, right, compare_iteration_order, root_name)
    _compare_iteration_order = compare_iteration_order
    visited = {}
    reference_value_locations = {}
    local result = compare_values(left, right, root_name or "ROOT")
    visited = nil
    reference_value_locations = nil
    local difference_result = difference
    difference = nil
    return result, difference_result
  end
end

return {
  deep_compare = deep_compare,
  difference_type = difference_type,
  do_not_compare_flag = do_not_compare_flag,
  register_custom_comparator = register_custom_comparator,
}
