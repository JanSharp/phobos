
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

---cSpell:ignore KPROTO

---Notes:\
---(*) In OP_CALL, if (B == 0) then B = top. If (C == 0), then `top` is
---set to last_result+1, so next open instruction (OP_CALL, OP_RETURN,
---OP_SETLIST) may use `top`.
---
---(*) In OP_VARARG, if (B == 0) then use actual number of varargs and
---set top (like in OP_CALL with C == 0).
---
---(*) In OP_RETURN, if (B == 0) then return up to `top`.
---
---(*) In OP_SETLIST, if (B == 0) then B = `top`; if (C == 0) then next
---'instruction' is EXTRAARG(real C).
---
---(*) In OP_LOADKX, the next 'instruction' is always EXTRAARG.
---
---(*) For comparisons, A specifies what condition the test should accept
---(true or false).
---
---(*) All `skips` (pc++) assume that next instruction is a jump.
---@class OpcodeUtilOpcodes
---@field move     Opcode @ (A, B)     |  R(A) := R(B)
---@field loadk    Opcode @ (A, Bx)    |  R(A) := Kst(Bx)
---@field loadkx   Opcode @ (A,)       |  R(A) := Kst(extra arg)
---@field loadbool Opcode @ (A, B, C)  |  R(A) := (Bool)B; if (C) pc++
---@field loadnil  Opcode @ (A, B)     |  R(A), R(A+1), ..., R(A+B) := nil
---@field getupval Opcode @ (A, B)     |  R(A) := UpValue[B]
---@field gettabup Opcode @ (A, B, C)  |  R(A) := UpValue[B][RK(C)]
---@field gettable Opcode @ (A, B, C)  |  R(A) := R(B)[RK(C)]
---@field settabup Opcode @ (A, B, C)  |  UpValue[A][RK(B)] := RK(C)
---@field setupval Opcode @ (A, B)     |  UpValue[B] := R(A)
---@field settable Opcode @ (A, B, C)  |  R(A)[RK(B)] := RK(C)
---@field newtable Opcode @ (A, B, C)  |  R(A) := {} (size = B,C)
---@field self     Opcode @ (A, B, C)  |  R(A+1) := R(B); R(A) := R(B)[RK(C)]
---@field add      Opcode @ (A, B, C)  |  R(A) := RK(B) + RK(C)
---@field sub      Opcode @ (A, B, C)  |  R(A) := RK(B) - RK(C)
---@field mul      Opcode @ (A, B, C)  |  R(A) := RK(B) * RK(C)
---@field div      Opcode @ (A, B, C)  |  R(A) := RK(B) / RK(C)
---@field mod      Opcode @ (A, B, C)  |  R(A) := RK(B) % RK(C)
---@field pow      Opcode @ (A, B, C)  |  R(A) := RK(B) ^ RK(C)
---@field unm      Opcode @ (A, B)     |  R(A) := -R(B)
---@field not      Opcode @ (A, B)     |  R(A) := not R(B)
---@field len      Opcode @ (A, B)     |  R(A) := length of R(B)
---@field concat   Opcode @ (A, B, C)  |  R(A) := R(B).. ... ..R(C)
---@field jmp      Opcode @ (A, sBx)   |  pc+=sBx; if (A) close all upvalues >= R(A) + 1
---@field eq       Opcode @ (A, B, C)  |  if ((RK(B) == RK(C)) ~= A) then pc++
---@field lt       Opcode @ (A, B, C)  |  if ((RK(B) <  RK(C)) ~= A) then pc++
---@field le       Opcode @ (A, B, C)  |  if ((RK(B) <= RK(C)) ~= A) then pc++
---@field test     Opcode @ (A, C)     |  if not (R(A) <=> C) then pc++
---@field testset  Opcode @ (A, B, C)  |  if (R(B) <=> C) then R(A) := R(B) else pc++
---@field call     Opcode @ (A, B, C)  |  R(A), ... ,R(A+C-2) := R(A)(R(A+1), ... ,R(A+B-1))
---@field tailcall Opcode @ (A, B, C)  |  return R(A)(R(A+1), ... ,R(A+B-1))
---@field return   Opcode @ (A, B)     |  return R(A), ... ,R(A+B-2) (see note)
---@field forloop  Opcode @ (A, sBx)   |  R(A)+=R(A+2); if R(A) <?= R(A+1) then { pc+=sBx; R(A+3)=R(A) }
---@field forprep  Opcode @ (A, sBx)   |  R(A)-=R(A+2); pc+=sBx
---@field tforcall Opcode @ (A, C)     |  R(A+3), ... ,R(A+2+C) := R(A)(R(A+1), R(A+2));
---@field tforloop Opcode @ (A, sBx)   |  if R(A+1) ~= nil then { R(A)=R(A+1); pc += sBx }
---@field setlist  Opcode @ (A, B, C)  |  R(A)[(C-1)*FPF+i] := R(A+i), 1 <= i <= B
---@field closure  Opcode @ (A, Bx)    |  R(A) := closure(KPROTO[Bx])
---@field vararg   Opcode @ (A, B)     |  R(A), R(A+1), ..., R(A+B-2) = vararg
---@field extraarg Opcode @ (Ax)       |  extra (larger) argument for previous opcode
local opcodes = {}

local next_id = 0
local opcodes_by_id = {}
local function op(name, params, special)
  local reduce_if_not_zero = {}
  local conditional = {}
  local next_op = special and special.next
  if special then
    special.next = nil
  end
  for k, v in pairs(special or {}) do
    if type(v) == "table" then
      if v.reduce_if_not_zero then
        reduce_if_not_zero[k] = v.reduce_if_not_zero
      elseif v.condition then
        conditional[k] = v.condition
      end
    end
  end

  local opcode = {
    id = next_id,
    name = name,
    label = string.upper(name),
    params = params,
    reduce_if_not_zero = reduce_if_not_zero,
    conditional = conditional,
    next_op = next_op,
  }

  opcodes[name] = opcode
  opcodes_by_id[next_id] = opcode

  next_id = next_id + 1
end

op("move", {a = register, b = register})
op("loadk", {a = register, bx = constant})
op("loadkx", {a = register, next = {name = "extraarg", ax = constant}})
op("loadbool", {a = register, b = bool, c = bool})
op("loadnil", {a = register, b = other})

op("getupval", {a = register, b = upval})
op("gettabup", {a = register, b = upval, c = register_or_constant})
op("gettable", {a = register, b = register, c = register_or_constant})
op("settabup", {a = upval, b = register_or_constant, c = register_or_constant})
op("setupval", {a = register, b = upval})
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
op("return", {a = register, b = other},
  {a = {condition = function(opcode) return opcode.b > 0 end}, b = if_not_zero_reduce_by(1)}
)

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
}
