
local util = require("util")
local linq = require("linq")
local stack = require("stack")

---@type table<string, fun(value:any):string>
local custom_pretty_printers = {}

local pretty_print

local identifier_pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$"
local reference_types_lut = util.invert{"table", "function", "userdata", "thread"}
local function pretty_print_table(tab)
  util.debug_assert(type(tab) == "table", "Attempt to 'pretty_print_table' a '"..type(tab).."'")
  local reference_values_lut = {} ---@type table<any, {value: any, count: integer}>
  local reference_values = {} ---@type {value: any, count: integer}[]
  local function count_references(value)
    local value_type = type(value)
    if not reference_types_lut[value_type] then return end
    if reference_values_lut[value] then
      reference_values_lut[value].count = reference_values_lut[value].count + 1
      return
    else
      local ref_value = {value = value, count = 1}
      reference_values_lut[value] = ref_value
      reference_values[#reference_values+1] = ref_value
    end
    if value_type ~= "table" then return end
    for key in linq(util.iterate_keys(value))
      :group_by(function(key) return type(key) end)
      :order_by(function(group) return group.key end)
      :select_many(function(group)
        if group.key == "number" or group.key == "string" then
          return linq(group):order()
        end
        return group
      end)
      :iterate()
    do
      count_references(key)
      count_references(value[key])
    end
  end
  count_references(tab)

  ---@type {value: any, count: integer, visited: boolean?, location_name: string?}[]
  local multiple_referenced_values = linq(reference_values)
    :where(function(ref_value) return ref_value.count > 1 end)
    :to_array()
  ;
  ---@type table<any, {value: any, count: integer, visited: boolean?, location_name: string?}>
  local multiple_referenced_values_lut = linq(multiple_referenced_values)
    :to_dict(function(data) return data.value, data end)
  ;

  local next_fallback_location_id = 1
  local invalid_location_count = 0
  local location_key_stack = stack.new_stack()
  local function get_fallback_location_name()
    local id = next_fallback_location_id
    next_fallback_location_id = id + 1
    return string.format("reference[%d]", id)
  end
  local function get_location_name()
    if invalid_location_count > 0 then
      return get_fallback_location_name()
    end
    local name_parts = {"root"}
    for i = 1, location_key_stack.size do
      local key = location_key_stack[i]
      local key_type = type(key)
      if key_type == "boolean" or key_type == "number" then
        name_parts[i + 1] = "["..pretty_print(key).."]"
        goto continue
      elseif key_type ~= "string" then
        return get_fallback_location_name()
      end
      -- key_type == "string"
      if key:find(identifier_pattern) then
        key = "."..key
      elseif key:find("[\n\r]") then
        return get_fallback_location_name()
      else
        key = "["..pretty_print(key).."]"
      end
      if #key > 32 then
        return get_fallback_location_name()
      end
      name_parts[i + 1] = key
      ::continue::
    end
    return table.concat(name_parts)
  end

  local out = {}
  local c = 0

  local function add_back_reference_location(multiple_referenced_value)
    if not multiple_referenced_value then return end
    multiple_referenced_value.visited = true
    multiple_referenced_value.location_name = get_location_name()
    c=c+1;out[c] = " --[[ "
    c=c+1;out[c] = multiple_referenced_value.location_name
    c=c+1;out[c] = string.format(" (%d) ]]", multiple_referenced_value.count)
  end

  local function pretty_print_recursive(value, depth)
    local multiple_referenced_value = multiple_referenced_values_lut[value]
    if multiple_referenced_value and multiple_referenced_value.visited then
      c=c+1;out[c] = "_--[[ "
      c=c+1;out[c] = multiple_referenced_value.location_name
      c=c+1;out[c] = " ]]"
      return
    end

    if type(value) ~= "table" then
      c=c+1;out[c] = pretty_print(value)
      add_back_reference_location(multiple_referenced_value)
      return
    end

    c=c+1;out[c] = "{"
    add_back_reference_location(multiple_referenced_value)
    local kvp_count = 0
    for key_data in linq(util.iterate_keys(value))
      :group_by(function(key) return type(key) end)
      :order_by(function(group) return group.key end)
      :select_many(function(group)
        local result = linq(group):select(function(k) return {type = group.key, key = k} end)
        if group.key == "number" or group.key == "string" then
          return result:order_by(function(k) return k.key end)
        end
        return result
      end)
      :iterate()
    do
      c=c+1;out[c] = "\n"..string.rep("  ", depth + 1)
      if key_data.type == "string" and key_data.key:find(identifier_pattern) then
        c=c+1;out[c] = key_data.key
        c=c+1;out[c] = " = "
      else
        c=c+1;out[c] = "["
        invalid_location_count = invalid_location_count + 1
        pretty_print_recursive(key_data.key, depth + 1)
        invalid_location_count = invalid_location_count - 1
        c=c+1;out[c] = "] = "
      end
      stack.push(location_key_stack, key_data.key)
      pretty_print_recursive(value[key_data.key], depth + 1)
      stack.pop(location_key_stack)
      c=c+1;out[c] = ","
      kvp_count = kvp_count + 1
    end
    if kvp_count > 0 then
      c=c+1;out[c] = "\n"..string.rep("  ", depth)
    elseif multiple_referenced_value then
      c=c+1;out[c] = " " -- extra space after --[[ root.foo.bar ]] `location_name`, only for empty tables
    end
    c=c+1;out[c] = "}"
  end

  pretty_print_recursive(tab, 0)

  return table.concat(out)
end

function pretty_print(value)
  local type = type(value)
  return (custom_pretty_printers[type] or ({
    ["number"] = function()
      if value ~= value then
        return "0/0"
      end
      if value == 1/0 then
        return "1/0"
      end
      if value == -1/0 then
        return "-1/0"
      end
      return tostring(value)
    end,
    ["string"] = function()
      return string.format("%q", value):gsub("\r", [[\r]])
    end,
    ["boolean"] = function()
      return tostring(value)
    end,
    ["nil"] = function()
      return "nil"
    end,
    ["table"] = function()
      return pretty_print_table(value)
    end,
    ["function"] = function()
      local info = debug.getinfo(value, "S")
      return "<"..tostring(value).." ("..info.short_src..")>"
    end,
    ["userdata"] = function()
      return tostring(value)
    end,
    ["thread"] = function()
      return tostring(value)
    end,
  })[type])(value)
end

return {
  custom_pretty_printers = custom_pretty_printers,
  pretty_print = pretty_print,
}
