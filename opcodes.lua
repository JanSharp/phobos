
local register = 1
local constant = 2
local register_or_constant = 3
local upval = 4
local bool = 5
local floating_byte = 6
local jump_pc_offset = 7
local other = 8

local param_types = {
  register = register,
  constant = constant,
  register_or_constant = register_or_constant,
  upval = upval,
  bool = bool,
  floating_byte = floating_byte,
  jump_pc_offset = jump_pc_offset,
  other = other,
}

local function if_not_zero_reduce_by(amount)
  return {reduce_if_not_zero = amount}
end

local next_id = 0
local opcodes = {}
local opcodes_by_id = {}
local opcode_name_lut = {}
local function op(name, params, special)
  local reduce_if_not_zero = {}
  for k, v in pairs(special or {}) do
    if type(v) == "table" and v.reduce_if_not_zero then
      reduce_if_not_zero[k] = v.reduce_if_not_zero
    end
  end

  local opcode = {
    id = next_id,
    name = name,
    params = params,
    reduce_if_not_zero = reduce_if_not_zero,
    next_op = special and special.next,
  }

  opcodes[name] = opcode
  opcodes_by_id[next_id] = opcode
  opcode_name_lut[next_id] = name

  next_id = next_id + 1
end

op("move", {a = register, b = register})
op("loadk", {a = register, bx = constant})
op("loadkx", {a = register, next = {op = "extraarg", ax = constant}})
op("loadbool", {a = register, b = bool, c = bool})
op("loadnil", {a = register, b = other})

op("getupval", {a = register, b = upval})
op("gettabup", {a = register, b = upval, c = register_or_constant})
op("gettable", {a = register, b = register, c = register_or_constant})
op("settabup", {a = upval, b = register_or_constant, c = register_or_constant})
op("setupval", {a = upval, b = register})
op("settable", {a = register, b = register_or_constant, c = register_or_constant})

op("newtable", {a = register, b = floating_byte, c = floating_byte})
op("self", {a = register, b = register, c = register_or_constant})

op("add", {a = register, b = register_or_constant, c = register_or_constant})
op("sub", {a = register, b = register_or_constant, c = register_or_constant})
op("mul", {a = register, b = register_or_constant, c = register_or_constant})
op("div", {a = register, b = register_or_constant, c = register_or_constant})
op("mod", {a = register, b = register_or_constant, c = register_or_constant})
op("pow", {a = register, b = register_or_constant, c = register_or_constant})
op("unm", {a = register, b = register_or_constant})
op("not", {a = register, b = register_or_constant})
op("len", {a = register, b = register_or_constant})

op("concat", {a = register, b = register, c = register})

op("jmp", {a = register, sbx = jump_pc_offset}, {a = if_not_zero_reduce_by(1)})
op("eq", {a = bool, b = register_or_constant, c = register_or_constant})
op("lt", {a = bool, b = register_or_constant, c = register_or_constant})
op("le", {a = bool, b = register_or_constant, c = register_or_constant})

op("test", {a = register, c = bool})
op("testset", {a = register, b = register, c = bool})

op("call", {a = register, b = other, c = other}, {b = if_not_zero_reduce_by(1), c = if_not_zero_reduce_by(1)})
op("tailcall", {a = register, b = other}, {b = if_not_zero_reduce_by(1)})
op("return", {a = register, b = other}, {b = if_not_zero_reduce_by(1)})

op("forloop", {a = register, sbx = jump_pc_offset})
op("forprep", {a = register, sbx = jump_pc_offset})
op("tforcall", {a = register, c = other})
op("tforloop", {a = register, sbx = jump_pc_offset})

op("setlist", {a = register, b = other, c = other},
  {next = {"extraarg", condition = function(opcode) return opcode.c == 0 end, ax = other}}
)
op("closure", {a = register, bx = other})
op("vararg", {a = register, b = other}, {b = if_not_zero_reduce_by(2)})
op("extraarg", {ax = other})

return {
  param_types = param_types,
  opcodes = opcodes,
  opcodes_by_id = opcodes_by_id,
  opcode_name_lut = opcode_name_lut,
}
