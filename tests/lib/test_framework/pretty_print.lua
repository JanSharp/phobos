
local util = require("util")
local linq = require("linq")

---@type table<string, fun(value:any):string>
local custom_pretty_printers = {}

local pretty_print

local reference_types_lut = util.invert{"table", "function", "userdata", "thread"}
local function pretty_print_table(tab)
  util.debug_assert(type(tab) == "table", "Attempt to 'pretty_print_table' a '"..type(tab).."'")
  local reference_counts_lut = {} ---@type table<any, {value: any, count: integer}>
  local reference_counts = {} ---@type {value: any, count: integer}[]
  local visited = {} ---@type table<any, true>
  local function count_references(t)
    if not reference_types_lut[type(t)] then return end
    if reference_counts_lut[t] then
      reference_counts_lut[t].count = reference_counts_lut[t].count + 1
    else
      local count_data = {value = t, count = 1}
      reference_counts_lut[t] = count_data
      reference_counts[#reference_counts+1] = count_data
    end
    if visited[t] then return end
    visited[t] = true
    for key in linq(util.iterate_keys(t))
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
      count_references(t[key])
    end
  end
  count_references(tab)

  ---@type {value: any, count: integer, index: integer}[]
  local multiple_referenced_values = linq(reference_counts)
    :where(function(count_data) return count_data.count > 1 end)
    :select(function(count_data, i) count_data.index = i; return count_data end)
    :to_array()
  ;
  ---@type table<any, {value: any, count: integer, index: integer}>
  local multiple_referenced_values_lut = linq(multiple_referenced_values)
    :to_dict(function(data) return data.value, data end)
  ;
  local out = {}
  local c = 0
  local function pretty_print_recursive(value, depth, do_not_back_reference)
    if multiple_referenced_values_lut[value] and not do_not_back_reference then
      c=c+1;out[c] = string.format("reference[%d]", multiple_referenced_values_lut[value].index)
      return
    end
    if type(value) ~= "table" then
      c=c+1;out[c] = pretty_print(value)
      return
    end

    c=c+1;out[c] = "{"
    local count = 0
    for key in linq(util.iterate_keys(value))
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
      if key.type == "string" and key.key:find("^[a-zA-Z_][a-zA-Z0-9_]*$") then
        c=c+1;out[c] = key.key
        c=c+1;out[c] = " = "
      else
        c=c+1;out[c] = "["
        pretty_print_recursive(key.key, depth + 1)
        c=c+1;out[c] = "] = "
      end
      pretty_print_recursive(value[key.key], depth + 1)
      c=c+1;out[c] = ","
      count = count + 1
    end
    if count > 0 then
      c=c+1;out[c] = "\n"..string.rep("  ", depth)
    end
    c=c+1;out[c] = "}"
  end

  for _, data in ipairs(multiple_referenced_values) do
    c=c+1;out[c] = string.format("reference[%d] = ", data.index)
    pretty_print_recursive(data.value, 0, true)
    c=c+1;out[c] = "\n"
  end

  c=c+1;out[c] = "root = "
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
