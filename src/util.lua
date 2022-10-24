
---converts an integer to a "floating point byte", represented as\
---cSpell: disable-next-line\
---(eeeeexxx), where the real value is (1xxx) * 2^(eeeee - 1) if eeeee != 0\
---otherwise just (xxx)
---@param x integer
---@return integer floating_point_byte @ 9 bits
local function number_to_floating_byte(x)
  if x < 8--[[0b1000]] then
    return x
  end
  local e = 0
  while x >= 0x10 do
    x = bit32.rshift(x + 1, 1)
    e = e + 1
  end
  return bit32.bor(bit32.lshift(e + 1, 3), x - 8)
end

---converts back
---@param x integer @ floating point byte (9 bits)
---@return integer
local function floating_byte_to_number(x)
  local e = bit32.band(bit32.rshift(x, 3), 0x1f)
  if e == 0 then
    return x
  end
  return bit32.lshift(bit32.band(x, 7--[[0b0111]]) + 8--[[0b1000]], e - 1)
end

---currently unused
local function clear_table(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys+1] = k
  end
  for _, k in ipairs(keys) do
    t[k] = nil
  end
end

local function clear_array(t)
  for i = #t, 1, -1 do
    t[i] = nil
  end
end

---@generic T
---@param array T[]
---@param element T
local function remove_from_array(array, element)
  for i = 1, #array do
    if array[i] == element then
      table.remove(array, i)
      break
    end
  end
end

local function replace_table(target, new_data)
  clear_table(target)
  for k, v in pairs(new_data) do
    target[k] = v
  end
end

local function shallow_copy(t)
  local result = {}
  for k, v in pairs(t) do
    result[k] = v
  end
  local meta = getmetatable(t)
  if meta then
    setmetatable(result, meta)
  end
  return result
end

local function optional_shallow_copy(t)
  if not t then return nil end
  return shallow_copy(t)
end

local function copy(t, copy_metatables)
  local visited = {}
  local function copy_recursive(value)
    if type(value) ~= "table" then
      return value
    end
    if visited[value] then
      return visited[value]
    end
    local result = {}
    visited[value] = result
    for k, v in pairs(value) do
      result[copy_recursive(k)] = copy_recursive(v)
    end
    local meta = getmetatable(value)
    if meta then
      setmetatable(result, copy_metatables and copy_recursive(meta) or meta)
    end
    return result
  end
  return copy_recursive(t)
end

--- Invert an array of keys to be a set of key=true
---@param t table<number,any>
---@return table<any,boolean>
local function invert(t)
  local tt = {}
  for _,s in pairs(t) do
    tt[s] = true
  end
  return tt
end

local function insert_range(target, range, target_index, range_start_index, range_stop_index)
  range_start_index = range_start_index or 1
  range_stop_index = range_stop_index or #range
  if not target_index then
    target_index = #target
  else
    local range_len = range_stop_index - range_start_index + 1
    for i = #target, target_index, -1 do
      target[i + range_len] = target[i]
    end
    target_index = target_index - 1
  end
  for i = range_start_index, range_stop_index do
    target[target_index + i] = range[i]
  end
end

local function remove_range(target, start_index, stop_index)
  local target_len = #target
  local range_len = stop_index - start_index + 1
  for i = start_index, target_len - range_len do
    target[i] = target[i + range_len]
    target[i + range_len] = nil
  end
end

local function replace_range(target, range, start_index, stop_index, range_start_index, range_stop_index)
  range_start_index = range_start_index or 1
  range_stop_index = range_stop_index or #range
  local target_range_len = stop_index - start_index + 1
  local range_len = range_stop_index - range_start_index + 1
  for i = 0, math.min(target_range_len, range_len) - 1 do
    target[start_index + i] = range[range_start_index + i]
  end
  if target_range_len > range_len then
    remove_range(target, start_index + range_len, stop_index)
  elseif range_len > target_range_len then
    insert_range(target, range, start_index + target_range_len, range_start_index + target_range_len, range_stop_index)
  end
end

local function debug_abort(message)
  return error(message)
end

local function abort(message)
  if os then -- factorio doesn't have `os`
    if message then
      io.stderr:write(message.."\n"):flush()
    end
    error() -- error without a message apparently doesn't end up printing anything to the console
    -- the benefit is that this can still be caught by pcall
    -- otherwise we use os.exit(false)
  else
    error(message)
  end
end

---`message` defaults to `"Assertion failed!"`
local function debug_assert(value, message)
  if not value then
    debug_abort(message or "Assertion failed!")
  end
  return value
end

---`message` does not default to `"Assertion failed!"`, it remains `nil` if it's `nil`
local function assert(value, message)
  if not value then
    abort(message)
  end
  return value
end

local reset = "\x1b[0m"
local magenta = "\x1b[35m"
local function debug_print(msg)
  print(msg and (magenta..msg..reset))
end

---@param text string
---@param i integer?
---@return table?
---@return integer?
local function parse_version(text, i)
  local major_str, minor_str, patch_str, end_pos = text:match("^(%d+)%.(%d+)%.(%d+)()", i)
  if not major_str then
    return nil, nil
  end
  local major = tonumber(major_str)
  local minor = tonumber(minor_str)
  local patch = tonumber(patch_str)
  if major == 0 and minor == 0 and patch == 0 then
    debug_abort("Version 0.0.0 is invalid")
  end
  return {
    major = major,
    minor = minor,
    patch = patch,
  }, end_pos
end

local function format_version(version)
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

local function assert_params_field(params, field_name)
  local value = params[field_name]
  if value == nil then
    debug_abort("Missing params field '"..field_name.."'")
  end
  return value
end

local function new_pos(line, column)
  return {
    line = line,
    column = column,
  }
end

local function pos_str(position)
  return (position and position.line or 0)..":"..(position and position.column or 0)
end

---@class ParsedInterpolatedString
---@field field_names string[] @ field names used in the interpolated string
---@field format_string string @ `string.format` pattern

---@param interpolated_string string
---@return ParsedInterpolatedString
local function parse_interpolated_string(interpolated_string)
  local field_names = {}
  local format_parts = {}
  do
    local function add_literal_part(str)
      format_parts[#format_parts+1] = str:gsub("%%", "%%%0")
      -- format_parts[#format_parts+1] = str:gsub("[%^$()%%.%[%]*+%-?]", "%%%0")
    end
    local name, options, trailing, pos, stop
    trailing, pos = interpolated_string:match("^([^{]*)()")
    add_literal_part(trailing)
    while true do
      name, trailing, stop = interpolated_string:match("^{([%a_][%w_]*)}([^{]*)()", pos)
      options = nil
      if not name then
        name, options, trailing, stop = interpolated_string:match("^{([%a_][%w_]*):(%%[^}]+)}([^{]*)()", pos)
      end
      if not name then
        break
      end
      field_names[#field_names+1] = name
      format_parts[#format_parts+1] = options or "%s" -- %s on non strings will `tostring` them
      add_literal_part(trailing)
      pos = stop
    end
    if pos <= #interpolated_string then
      debug_abort("Malformed interpolated string '"..interpolated_string
        .."', stopped parsing at "..(pos - 1).."."
      )
    end
  end
  return {
    field_names = field_names,
    format_string = table.concat(format_parts),
  }
end

---@param interpolated_string string|ParsedInterpolatedString @
---if this is a `string` it will be parsed using `parse_interpolated_string`
---@param data table @ table containing all fields used by the interpolated string
---@return string
local function format_interpolated(interpolated_string, data)
  if type(interpolated_string) == "string" then
    interpolated_string = parse_interpolated_string(interpolated_string)
  end
  local args = {}
  for i, field_name in ipairs(interpolated_string.field_names) do
    local field = data[field_name]
    if field == nil then
      debug_abort("Attempt to format field '"..field_name.."' in an interpolated string where no such field \z
        is in the provided data table."
      )
    end
    args[i] = field
  end
  return interpolated_string.format_string:format(table.unpack(args))
end

return {
  number_to_floating_byte = number_to_floating_byte,
  floating_byte_to_number = floating_byte_to_number,
  invert = invert,
  clear_table = clear_table,
  clear_array = clear_array,
  remove_from_array = remove_from_array,
  replace_table = replace_table,
  shallow_copy = shallow_copy,
  optional_shallow_copy = optional_shallow_copy,
  copy = copy,
  insert_range = insert_range,
  remove_range = remove_range,
  replace_range = replace_range,
  debug_abort = debug_abort,
  abort = abort,
  debug_assert = debug_assert,
  assert = assert,
  debug_print = debug_print,
  parse_version = parse_version,
  format_version = format_version,
  assert_params_field = assert_params_field,
  new_pos = new_pos,
  pos_str = pos_str,
  parse_interpolated_string = parse_interpolated_string,
  format_interpolated = format_interpolated,
}
