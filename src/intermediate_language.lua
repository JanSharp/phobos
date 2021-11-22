
---@alias ILPointerType
---| '"reg"'
---| '"number"'
---| '"string"'
---| '"boolean"'
---| '"nil"'

---@class ILPointer
---@field ptr_type ILPointerType

---@class ILRegister : ILPointer
---@field ptr_type '"reg"'

---@class ILNumber : ILPointer
---@field ptr_type '"number"'
---@field value number

---@class ILString : ILPointer
---@field ptr_type '"string"'
---@field value string

---@class ILBoolean : ILPointer
---@field ptr_type '"boolean"'
---@field value boolean

---@class ILNil : ILPointer
---@field ptr_type '"nil"'

local function is_reg(ptr)
  return ptr.ptr_type == "reg"
end

local function is_const(ptr)
  return ptr.ptr_type ~= "reg"
end

local function assert_field(params, field_name)
  return assert(params[field_name], "missing field '"..field_name.."'")
end

local function assert_reg(params, field_name)
  local field = assert_field(params, field_name)
  assert(is_reg(field), "field '"..field_name.."' must be a register")
  return field
end

local function assert_ptr(params, field_name)
  local field = assert_field(params, field_name)
  assert(field.ptr_type, "field '"..field_name.."' must be a pointer")
  return field
end

---@class ILPosition
---@field leading Token[]
---@field line number
---@field column number

---@class ILInstParamsBase
---@field position ILPosition

---@alias ILInstructionType
---| '"move"'
---| '"get_upval"'
---| '"set_upval"'
---| '"get_table"'
---| '"set_table"'
---| '"new_table"'
---| '"binop"'
---| '"unop"'
---| '"label"'
---| '"jump"'
---| '"test"'
---| '"call"'
---| '"ret"'
---| '"closure"'
---| '"vararg"'

local function new_inst(params, inst_type)
  return {inst_type = inst_type, position = params.position}
end

---@class ILMoveParams : ILInstParamsBase
---@field result_reg ILRegister
---@field right_ptr ILPointer

---@param params ILMoveParams
local function new_move(params)
  local inst = new_inst(params, "move")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILGetUpvalParams : ILInstParamsBase
---@field result_reg ILRegister
---@field upval any @ -- TODO: type

---@param params ILGetUpvalParams
local function new_get_upval(params)
  local inst = new_inst(params, "get_upval")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.upval = assert_field(params, "upval")
  return inst
end

---@class ILSetUpvalParams : ILInstParamsBase
---@field upval any @ -- TODO: type
---@field right_ptr ILPointer

---@param params ILGetUpvalParams
local function new_set_upval(params)
  local inst = new_inst(params, "set_upval")
  inst.upval = assert_field(params, "upval")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILGetTableParams : ILInstParamsBase
---@field result_reg ILRegister
---@field table_reg ILRegister
---@field key_ptr ILPointer

---@param params ILGetUpvalParams
local function new_get_table(params)
  local inst = new_inst(params, "get_table")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.table_reg = assert_reg(params, "table_reg")
  inst.key_ptr = assert_ptr(params, "key_ptr")
  return inst
end

---@class ILSetTableParams : ILInstParamsBase
---@field table_reg ILRegister
---@field key_ptr ILPointer
---@field right_ptr ILPointer

---@param params ILGetUpvalParams
local function new_set_table(params)
  local inst = new_inst(params, "set_table")
  inst.table_reg = assert_reg(params, "table_reg")
  inst.key_ptr = assert_ptr(params, "key_ptr")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILNewTableParams : ILInstParamsBase
---@field result_reg ILRegister
---@field array_size integer|nil
---@field hash_size integer|nil

---@param params ILNewTableParams
local function new_new_table(params)
  local inst = new_inst(params, "new_table")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.array_size = params.array_size or 0
  inst.hash_size = params.hash_size or 0
  return inst
end

---@class ILBinopParams : ILInstParamsBase
---@field result_reg ILRegister
---@field op AstBinOpOp|'".."'
---@field left_ptr ILPointer
---@field right_ptr ILPointer

---@param params ILBinopParams
local function new_binop(params)
  local inst = new_inst(params, "binop")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.op = assert_field(params, "op")
  inst.left_ptr = assert_ptr(params, "left_ptr")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILUnopParams : ILInstParamsBase
---@field result_reg ILRegister
---@field op AstUnOpOp
---@field right ILPointer

---@param params ILUnopParams
local function new_unop(params)
  local inst = new_inst(params, "unop")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.op = assert_field(params, "op")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILLabelParams : ILInstParamsBase
---@field name string|nil

---@param params ILLabelParams
local function new_label(params)
  local inst = new_inst(params, "label")
  inst.name = params.name
  return inst
end

---@class ILJumpParams : ILInstParamsBase
---@field label any @ -- TODO: type

---@param params ILJumpParams
local function new_jump(params)
  local inst = new_inst(params, "jump")
  inst.label = assert_field(params, "label")
  return inst
end

---@class ILTestParams : ILInstParamsBase
---@field label any @ -- TODO: type
---@field condition ILPointer

---@param params ILJumpParams
local function new_test(params)
  local inst = new_inst(params, "test")
  inst.label = assert_field(params, "label")
  inst.condition = assert_ptr(params, "condition")
  return inst
end

---@class ILCallParams : ILInstParamsBase
---@field func_reg ILRegister
---@field args ILPointer[]|nil
---@field result_regs ILRegister[]|nil
---@field consume_vararg boolean|nil
---@field vararg_result boolean|nil

---@param params ILCallParams
local function new_call(params)
  local inst = new_inst(params, "call")
  inst.func_reg = assert_reg(params, "func_reg")
  inst.args = params.args or {}
  inst.result_regs = params.result_regs or {}
  inst.consume_vararg = params.consume_vararg or false
  inst.vararg_result = params.vararg_result or false
  return inst
end

---@class ILRetParams : ILInstParamsBase
---@field ptrs ILPointer[]|nil
---@field consume_vararg boolean|nil

---@param params ILRetParams
local function new_ret(params)
  local inst = new_inst(params, "ret")
  inst.func_reg = assert_reg(params, "func_reg")
  inst.ptrs = params.ptrs or {}
  inst.consume_vararg = params.consume_vararg or false
  return inst
end

---@class ILClosureParams : ILInstParamsBase
---@field result_reg ILRegister
---@field func any @ -- TODO: type

---@param params ILClosureParams
local function new_closure(params)
  local inst = new_inst(params, "closure")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.func = assert_field(params, "func")
  return inst
end

---@class ILVarargParams : ILInstParamsBase
---@field result_regs ILRegister[]|nil
---@field vararg_result boolean|nil

---@param params ILVarargParams
local function new_vararg(params)
  local inst = new_inst(params, "vararg")
  inst.result_regs = params.result_regs or {}
  inst.vararg_result = params.vararg_result or false
  return inst
end

local function new_reg()
  return {}
end
