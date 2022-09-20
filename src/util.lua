
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

return {
  number_to_floating_byte = number_to_floating_byte,
  floating_byte_to_number = floating_byte_to_number,
  invert = invert,
  clear_table = clear_table,
  replace_table = replace_table,
  shallow_copy = shallow_copy,
  copy = copy,

}
