
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

local get_main_position
do
  local getter_lut = {
    ["env_scope"] = function(node)
      error("node_type 'env_scope' is purely fake and therefore has no main position")
      return nil
    end,
    ["functiondef"] = function(node)
      return node.function_token
    end,
    ["token"] = function(node)
      return node
    end,
    ["empty"] = function(node)
      return node.semi_colon_token
    end,
    ["ifstat"] = function(node)
      return get_main_position(node.ifs[1])
    end,
    ["testblock"] = function(node)
      return node.if_token
    end,
    ["elseblock"] = function(node)
      return node.else_token
    end,
    ["whilestat"] = function(node)
      return node.while_token
    end,
    ["dostat"] = function(node)
      return node.do_token
    end,
    ["fornum"] = function(node)
      return node.for_token
    end,
    ["forlist"] = function(node)
      return node.for_token
    end,
    ["repeatstat"] = function(node)
      return node.repeat_token
    end,
    ["funcstat"] = function(node)
      return get_main_position(node.func_def)
    end,
    ["localstat"] = function(node)
      return node.local_token
    end,
    ["localfunc"] = function(node)
      return node.local_token
    end,
    ["label"] = function(node)
      return node.open_token
    end,
    ["retstat"] = function(node)
      return node.return_token
    end,
    ["breakstat"] = function(node)
      return node.break_token
    end,
    ["gotostat"] = function(node)
      return node.goto_token
    end,
    ["selfcall"] = function(node)
      return node.colon_token
    end,
    ["call"] = function(node)
      return node.open_paren_token
    end,
    ["assignment"] = function(node)
      return node.eq_token
    end,
    ["local_ref"] = function(node)
      return node
    end,
    ["upval_ref"] = function(node)
      return node
    end,
    ["index"] = function(node)
      if node.suffix.node_type == "string" and node.suffix.src_is_ident then
        if node.src_ex_did_not_exist then
          return node.suffix
        else
          return node.dot_token
        end
      else
        return node.suffix_open_token
      end
    end,
    ["ident"] = function(node)
      return node
    end,
    ["unop"] = function(node)
      return node.op_token
    end,
    ["binop"] = function(node)
      return node.op_token
    end,
    ["concat"] = function(node)
      return node.op_tokens and node.op_tokens[1]
    end,
    ["number"] = function(node)
      return node
    end,
    ["string"] = function(node)
      return node
    end,
    ["nil"] = function(node)
      return node
    end,
    ["boolean"] = function(node)
      return node
    end,
    ["vararg"] = function(node)
      return node
    end,
    ["func_proto"] = function(node)
      return get_main_position(node.func_def)
    end,
    ["constructor"] = function(node)
      return node.open_token
    end,
    ["inline_iife_retstat"] = function(node)
      return node.return_token
    end,
    ["loopstat"] = function(node)
      return node.open_token
    end,
    ["inline_iife"] = function(node)
      -- TODO: when refactoring inline_iife add some main position
      return node.body.first and get_main_position(node.body.first.value)
    end,
  }
  function get_main_position(node)
    return getter_lut[node.node_type](node)
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
  get_main_position = get_main_position,
}
