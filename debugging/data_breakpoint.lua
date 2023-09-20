
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

---@class DataBreakpointBreakDefinition
---@field break_on_read fun(key: any)|{any: true}|(any[])|nil
---@field break_on_write fun(key: any, old: any, new: any)|{any: true}|(any[])|nil

---@generic T
---@param tab T
---@param break_definition DataBreakpointBreakDefinition
---@return T
local function data_breakpoint(tab, break_definition)
  assert(getmetatable(tab) == nil, "Data breakpoints on tables with metatables is not supported.")

  -- move values from tab to a new table
  local values = {}
  for k, v in pairs(tab) do
    values[k] = v
  end
  for k in pairs(values) do
    tab[k] = nil
  end

  local break_on_read_lut, break_on_read_callback = convert_to_lut_or_callback(break_definition.break_on_read)
  local break_on_write_lut, break_on_write_callback = convert_to_lut_or_callback(break_definition.break_on_write)

  -- set metatable
  return setmetatable(tab, {
    __index = function(_, key)
      if break_on_read_lut and break_on_read_lut[key]
        or break_on_read_callback and break_on_read_callback(key)
      then
        local current_value = values[key]
        hit_break_point()
      end
      return values[key]
    end,
    __newindex = function(_, key, new_value)
      if break_on_write_lut and break_on_write_lut[key]
        or break_on_write_callback and break_on_write_callback(key, values[key], new_value)
      then
        ---cSpell:ignore currentline
        local old_value = values[key]
        local info = debug.getinfo(2, "Sl")
        print("Written to '"..tostring(key).."' ('"..tostring(old_value).."' => '"..tostring(new_value).."') \z
          at "..info.short_src..":"..(info.currentline or 0)
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

return data_breakpoint
