
---cSpell:ignore userdata, upval, upvals, nups, bytecode, metatable

local pretty_print = require("pretty_print")

-- deep compare compares the contents of 2 values

-- tables are compared by identity,
-- if not equal then by their contents including iteration order

-- functions are compared by identity,
-- if not equal then by bytecode and all their upvals

local do_not_compare_flag = {"do_not_compare_flag"}

local custom_comparators = setmetatable({}, {__mode = "k"})
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
  custom_comparators[comparator] = true
  custom_comparators_allow_nil[comparator] = allow_nil or nil
  return comparator
end

local deep_compare
local difference_type = {
  value_type = 1, -- type of left and right are different
  c_function = 2, -- left or right are a c function while the other is either a non-c function or a different c function
  function_bytecode = 3, -- left and right are functions with differing bytecode
  primitive_value = 4, -- left and right are the same type, may only be a string, boolean or number but have different values
  size = 5, -- left and right are tables of different sizes, but up to the point where one ends they are equal
  identity_mismatch = 6, -- a reference value was visited before, but a second time they used different identities
  custom_comparator_func = 7, -- a custom comparator function deems a value incorrect
  custom_comparator_table = 8, -- a custom comparator table did not contain the other value
}
do
  local visited
  local location_stack
  local location_stack_size
  local compare_tables
  local difference
  local _compare_iteration_order

  local function create_location()
    return table.concat(location_stack, nil, 1, location_stack_size)
  end

  local function create_difference(diff_type, left, right)
    difference = {
      type = diff_type,
      location = create_location(),
      left = left,
      right = right,
    }
  end

  local compare_values

  local function use_custom_comparator(comparator, other, other_is_left)
    if visited[other] ~= nil then
      return true
    end
    if other ~= nil then
      visited[other] = true
    end
    if type(comparator) == "table" then
      if other == nil then
        if custom_comparators_allow_nil[comparator] then
          return true
        end
        difference = {
          type = difference_type.custom_comparator_table,
          location = create_location(),
          comparator = comparator,
          other = other,
          other_is_left = other_is_left,
        }
        return false
      end
      if comparator[other] then
        return true
      end
      local init_location_stack_size = location_stack_size
      local differences = {}
      for value_to_compare in pairs(comparator) do
        local old_visited = {}
        for k, v in pairs(visited) do
          old_visited[k] = v
        end
        local result
        if other_is_left then
          result = compare_values(other, value_to_compare)
        else
          result = compare_values(value_to_compare, other)
        end
        if result then
          visited[value_to_compare] = nil
          return true
        end
        differences[#differences+1] = difference
        difference = nil
        visited = old_visited
        location_stack_size = init_location_stack_size
      end
      difference = {
        type = difference_type.custom_comparator_table,
        location = create_location(),
        comparator = comparator,
        other = other,
        other_is_left = other_is_left,
        inner_differences = differences,
      }
      return false
    elseif type(comparator) == "function" then
      local success, message, data = comparator(other, other_is_left)
      if not success then
        difference = {
          type = difference_type.custom_comparator_func,
          location = create_location(),
          comparator = comparator,
          other = other,
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

  function compare_values(left, right)
    -- one of them is flagged as "don't compare these", so don't
    if left == do_not_compare_flag or right == do_not_compare_flag then
      return true
    end

    -- check for custom comparators and use those if present
    if custom_comparators[left] then
      if custom_comparators[right] then
        error("Comparing 2 custom comparators is not supported")
      end
      return use_custom_comparator(left, right, false)
    end
    if custom_comparators[right] then
      return use_custom_comparator(right, left, true)
    end

    -- check if it has already been visited
    if visited[left] ~= nil or visited[right] ~= nil then
      -- TODO: this is complaining about identity mismatches for custom comparators, even though [...]
      -- they should be completely excluded from identity checking
      -- if visited[left] == nil or visited[right] == nil
      --   or visited[left] ~= right -- if `visited[left] == right` then `visited[right] == left` is also true
      -- then
      --   create_difference(difference_type.identity_mismatch, left, right)
      --   return false
      -- end
      return true
    end

    -- compare nil, boolean, string, number (including NAN)
    if left == right or (left ~= left and right ~= right) then
      return true
    end
    local left_type = type(left)
    local right_type = type(right)
    if left_type ~= right_type then
      create_difference(difference_type.value_type, left, right)
      return false
    end

    -- after type check, `left` and `right` can't be nil anymore
    visited[left] = right
    visited[right] = left

    if left_type == "thread" then
      error("How did you even get a thread?")
    elseif left_type == "userdata" then
      -- TODO: check if that's even true, but it doesn't really matter right now
      error("Cannot compare userdata")
    elseif left_type == "function" then
      local left_info = debug.getinfo(left, "Su")
      local right_info = debug.getinfo(left, "S")
      if left_info.what == "C" or right_info.what == "C" then
        -- equality was already compared at the start, they are not equal
        -- or one isn't a c function
        create_difference(difference_type.c_function, left, right)
        return false
      end
      if string.dump(left) ~= string.dump(right) then
        create_difference(difference_type.function_bytecode, left, right)
        return false
      end
      -- compare upvals
      location_stack_size = location_stack_size + 1
      for i = 1, left_info.nups do
        local name, left_value = debug.getupvalue(left, i)
        local _, right_value = debug.getupvalue(right, i)
        location_stack[location_stack_size] = "[upval #"..i.." ("..name..")]"
        if not compare_values(left_value, right_value) then
          return false
        end
      end
      location_stack_size = location_stack_size - 1
      return true
    elseif left_type == "table" then
      return compare_tables(left, right)
    end

    create_difference(difference_type.primitive_value, left, right)
    return false
  end

  function compare_tables(left, right)
    if _compare_iteration_order then
      local left_key, left_value = next(left)
      local right_key, right_value = next(right)
      location_stack_size = location_stack_size + 1
      local kvp_num = 0
      while left_key ~= nil do
        kvp_num = kvp_num + 1

        location_stack[location_stack_size] = "[key #"..kvp_num.."]"
        if right_key == nil then
          -- TODO: add more info about table sizes
          -- TODO: add support for do_not_compare
          create_difference(difference_type.size, left, right)
          return false
        end
        if not compare_values(left_key, right_key) then
          return false
        end

        location_stack[location_stack_size] = "["..pretty_print(left_key).." (value #"..kvp_num..")]"
        if not compare_values(left_value, right_value) then
          return false
        end

        left_key, left_value = next(left, left_key)
        right_key, right_value = next(right, right_key)
      end
      location_stack_size = location_stack_size - 1
      if right_key ~= nil then
        -- TODO: add more info about table sizes
        -- TODO: add support for do_not_compare
        create_difference(difference_type.size, left, right)
        return false
      end
    else
      location_stack_size = location_stack_size + 1
      local done = {}
      for k, v in pairs(left) do
        location_stack[location_stack_size] = "["..pretty_print(k).."]"
        done[k] = true
        local r_v = right[k]
        if not compare_values(v, r_v) then
          return false
        end
      end
      for k, v in pairs(right) do
        if not done[k] then
          location_stack[location_stack_size] = "["..pretty_print(k).."]"
          if not compare_values(nil, v) then
            return false
          end
          error("impossible because 'v' can never be nil inside of the for loop")
        end
      end
      location_stack_size = location_stack_size - 1
    end

    local left_meta = debug.getmetatable(left)
    local right_meta = debug.getmetatable(right)
    if left_meta ~= nil or right_meta ~= nil then
      assert(type(left_meta) == "table", "Unexpected metatable type '"..type(left_meta).."'")
      assert(type(right_meta) == "table", "Unexpected metatable type '"..type(right_meta).."'")
      location_stack_size = location_stack_size + 1
      location_stack[location_stack_size] = "[metatable]"
      local result = compare_values(left_meta, right_meta)
      location_stack_size = location_stack_size - 1
      return result
    end

    return true
  end

  function deep_compare(left, right, compare_iteration_order, root_name)
    _compare_iteration_order = compare_iteration_order
    visited = {}
    location_stack = {root_name or "ROOT"}
    location_stack_size = 1
    local result = compare_values(left, right)
    location_stack = nil
    visited = nil
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
