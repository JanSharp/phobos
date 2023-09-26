
local pairs = pairs
local type = type
local error = error
local assert = assert
local getmetatable = getmetatable
local raw_setmetatable = setmetatable
local print = print
local tostring = tostring
local ipairs = ipairs
local next = next
local debug_getinfo = debug.getinfo
local debug_traceback = debug.traceback

---@type table<table, true>
local all_hooked_tables = setmetatable({}, {__mode = "k"})

local function hit_break_point()
  local b -- put a breakpoint here (or call a break function if the debugger has one)
end

local function invert(tab)
  local inverted = {}
  for _, v in pairs(tab) do
    inverted[v] = true
  end
  return inverted
end

---@return table<any, true>?, function?
local function convert_to_lut_or_callback(array_or_func)
  local t = type(array_or_func)
  if t == "table" then
    ---@diagnostic disable-next-line: undefined-field
    if array_or_func.any then
      return nil, function() return true end
    end
    return invert(array_or_func), nil
  end
  if t == "function" then
    return nil, array_or_func
  end
  if t ~= "nil" then
    error("Expected a table (array of keys, or with the field 'any' set to true) \z
      or a function as a break on condition."
    )
  end
  return nil, nil
end

local is_printing = false
---@param print_stacktrace boolean?
---@param msg string
local function wrapped_print(print_stacktrace, msg)
  ---cSpell:ignore currentline
  is_printing = true
  local info = debug_getinfo(3, "Sl")
  msg = msg.." at "..info.short_src..":"..(info.currentline or 0)
  print(print_stacktrace and debug_traceback(msg, 3) or msg)
  is_printing = false
end

---@class DataBreakpointBreakDefinition
---@field print_stacktrace boolean?
---@field break_on_read (fun(key: any): boolean?)|{any: true}|(any[])|nil
---@field break_on_write (fun(key: any, old: any, new: any): boolean?)|{any: true}|(any[])|nil

---@generic T
---@param tab T
---@param values T
---@param break_definition DataBreakpointBreakDefinition
---@return T
local function hook_internal(tab, values, break_definition)
  local print_stacktrace = break_definition.print_stacktrace
  local break_on_read_lut, break_on_read_callback = convert_to_lut_or_callback(break_definition.break_on_read)
  local break_on_write_lut, break_on_write_callback = convert_to_lut_or_callback(break_definition.break_on_write)

  all_hooked_tables[tab] = true

  -- set metatable
  return raw_setmetatable(tab, {
    is_data_breakpoint = true,
    values = values,
    break_definition = break_definition,

    __index = function(_, key)
      if not is_printing and (
        break_on_read_lut and break_on_read_lut[key]
        or break_on_read_callback and break_on_read_callback(key))
      then
        local current_value = values[key]
        wrapped_print(print_stacktrace, "Reading from '"..tostring(key)
          .."' ('"..tostring(current_value).."')"
        )
        hit_break_point()
      end
      return values[key]
    end,
    __newindex = function(_, key, new_value)
      if break_on_write_lut and break_on_write_lut[key]
        or break_on_write_callback and break_on_write_callback(key, values[key], new_value)
      then
        local old_value = values[key]
        wrapped_print(print_stacktrace, "Writing to '"..tostring(key)
          .."' ('"..tostring(old_value).."' => '"..tostring(new_value).."')"
        )
        hit_break_point()
      end
      values[key] = new_value
    end,
    __pairs = function()
      ---@diagnostic disable-next-line: redundant-return-value
      return pairs(values)
    end,
    __ipairs = function()
      ---@diagnostic disable-next-line: redundant-return-value
      return ipairs(values)
    end,
    __len = function()
      return #values
    end,
  })
end

---@generic T
---@param tab T
---@param break_definition DataBreakpointBreakDefinition
---@return T
local function hook(tab, break_definition)
  assert(getmetatable(tab) == nil, "Data breakpoints on tables with metatables is not supported.")

  -- move values from tab to a new table
  local values = {}
  for k, v in pairs(tab) do
    values[k] = v
  end
  for k in pairs(values) do
    tab[k] = nil
  end

  return hook_internal(tab, values, break_definition)
end

---@generic T
---@param tab T
---@param silent boolean? @ Suppress the "can only unhook hooked tables" warning?
---@return T
local function unhook(tab, silent)
  local meta = getmetatable(tab)
  if not (meta and meta.is_data_breakpoint) then
    if not silent then
      print("Can only unhook tables that are currently hooked as a data breakpoint. Ignoring.")
    end
    return tab
  end
  raw_setmetatable(tab, nil)
  for k, v in pairs(meta.values) do
    tab[k] = v
  end
  all_hooked_tables[tab] = nil
  return tab
end

local function unhook_all()
  local tab = next(all_hooked_tables)
  while tab do
    local next_tab = next(all_hooked_tables, tab)
    unhook(tab)
    tab = next_tab
  end
end

---@generic T
---@param t T
---@return T
local function shallow_copy(t)
  local result = {}
  for k, v in pairs(t) do
    result[k] = v
  end
  return result
end

function setmetatable(table, metatable)
  if not metatable or not metatable.is_data_breakpoint then
    return raw_setmetatable(table, metatable)
  end
  return hook_internal(table, shallow_copy(metatable.values), metatable.break_definition)
end

return {
  hook = hook,
  unhook = unhook,
  unhook_all = unhook_all,
}
