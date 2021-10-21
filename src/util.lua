
local invert = require("invert")

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

---@param upval_def AstUpvalDef
local function upval_is_in_stack(upval_def)
  return upval_def.parent_def.def_type == "local"
end

local function is_falsy(node)
  return node.node_type == "nil" or (node.node_type == "boolean" and node.value == false)
end

local const_node_type_lut = invert{"string","number","boolean","nil"}
local function is_const_node(node)
  return const_node_type_lut[node.node_type]
end
local function is_const_node_type(node_type)
  return const_node_type_lut[node_type]
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

return {
  number_to_floating_byte = number_to_floating_byte,
  floating_byte_to_number = floating_byte_to_number,
  upval_is_in_stack = upval_is_in_stack,
  is_falsy = is_falsy,
  is_const_node = is_const_node,
  is_const_node_type = is_const_node_type,
  clear_table = clear_table,
}
