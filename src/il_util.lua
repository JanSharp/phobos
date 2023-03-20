
local util = require("util")
local number_ranges = require("number_ranges")
local error_code_util = require("error_code_util")
local ill = require("indexed_linked_list")
local linq = require("linq")

----------------------------------------------------------------------------------------------------
-- instructions
----------------------------------------------------------------------------------------------------

local function is_reg(ptr)
  return ptr.ptr_type == "reg"
end

local function is_const(ptr)
  return not is_reg(ptr)
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

---@class ILInstParamsBase
---@field position ILPosition?

local function new_inst(params, inst_type)
  return {
    inst_type = inst_type,
    position = params.position,
  }
end

---@class ILInstGroupParamsBase
---@field position ILPosition?
---@field start ILInstruction
---@field stop ILInstruction

---@param group_type ILInstructionGroupType
---@param params ILInstGroupParamsBase
local function new_instruction_group(group_type, params)
  local group = {
    group_type = group_type,
    position = params.position,
    start = assert_field(params, "start"),
    stop = assert_field(params, "stop"),
  }
  local inst = group.start
  while inst ~= group.stop.next do
    inst.inst_group = group
    inst = inst.next
  end
  return group
end

---@class ILForprepGroupParams : ILInstGroupParamsBase
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field loop_jump ILJump

---@param params ILForprepGroupParams
---@return ILForprepGroup
local function new_forprep_group(params)
  local group = new_instruction_group("forprep", params)
  group.index_reg = assert_reg(params, "index_reg")
  group.limit_reg = assert_reg(params, "limit_reg")
  group.step_reg = assert_reg(params, "step_reg")
  group.loop_jump = assert_field(params, "loop_jump")
  return group
end

---@class ILForloopGroupParams : ILInstGroupParamsBase
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field loop_jump ILJump

---@param params ILForloopGroupParams
---@return ILForloopGroup
local function new_forloop_group(params)
  local group = new_instruction_group("forloop", params)
  group.index_reg = assert_reg(params, "index_reg")
  group.limit_reg = assert_reg(params, "limit_reg")
  group.step_reg = assert_reg(params, "step_reg")
  group.loop_jump = assert_field(params, "loop_jump")
  return group
end

---@class ILTforcallGroupParams : ILInstGroupParamsBase

---@param params ILTforcallGroupParams
---@return ILTforcallGroup
local function new_tforcall_group(params)
  local group = new_instruction_group("tforcall", params)
  return group
end

---@class ILTforloopGroupParams : ILInstGroupParamsBase

---@param params ILTforloopGroupParams
---@return ILTforloopGroup
local function new_tforloop_group(params)
  local group = new_instruction_group("tforloop", params)
  return group
end

---@class ILMoveParams : ILInstParamsBase
---@field result_reg ILRegister
---@field right_ptr ILPointer

---@param params ILMoveParams
---@return ILMove
local function new_move(params)
  local inst = new_inst(params, "move")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILGetUpvalParams : ILInstParamsBase
---@field result_reg ILRegister
---@field upval ILUpval

---@param params ILGetUpvalParams
---@return ILGetUpval
local function new_get_upval(params)
  local inst = new_inst(params, "get_upval")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.upval = assert_field(params, "upval")
  return inst
end

---@class ILSetUpvalParams : ILInstParamsBase
---@field upval ILUpval
---@field right_ptr ILPointer

---@param params ILSetUpvalParams
---@return ILSetUpval
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

---@param params ILGetTableParams
---@return ILGetTable
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

---@param params ILSetTableParams
---@return ILSetTable
local function new_set_table(params)
  local inst = new_inst(params, "set_table")
  inst.table_reg = assert_reg(params, "table_reg")
  inst.key_ptr = assert_ptr(params, "key_ptr")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

---@class ILSetListParams : ILInstParamsBase
---@field table_reg ILRegister
---@field start_index integer
---@field right_ptrs ILPointer[] @ The last one can be an `ILVarargRegister`

---@param params ILSetListParams
---@return ILSetList
local function new_set_list(params)
  local inst = new_inst(params, "set_list")
  inst.table_reg = assert_reg(params, "table_reg")
  inst.start_index = assert_field(params, "start_index")
  inst.right_ptrs = params.right_ptrs or {}
  return inst
end

---@class ILNewTableParams : ILInstParamsBase
---@field result_reg ILRegister
---@field array_size integer|nil
---@field hash_size integer|nil

---@param params ILNewTableParams
---@return ILNewTable
local function new_new_table(params)
  local inst = new_inst(params, "new_table")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.array_size = params.array_size or 0
  inst.hash_size = params.hash_size or 0
  return inst
end

---@class ILConcatParams : ILInstParamsBase
---@field result_reg ILRegister
---@field right_ptrs ILPointer[]

---@param params ILConcatParams
---@return ILConcat
local function new_concat(params)
  local inst = new_inst(params, "concat")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.right_ptrs = params.right_ptrs or {}
  return inst
end

---@class ILBinopParams : ILInstParamsBase
---@field result_reg ILRegister
---@field op AstBinOpOp
---@field left_ptr ILPointer
---@field right_ptr ILPointer
---@field raw boolean

---@param params ILBinopParams
---@return ILBinop
local function new_binop(params)
  local inst = new_inst(params, "binop")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.op = assert_field(params, "op")
  util.debug_assert(params.op ~= "and" and params.op ~= "or",
    "Use jumps for '"..params.op.."' ('and' and 'or') binops in IL"
  )
  inst.left_ptr = assert_ptr(params, "left_ptr")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  inst.raw = params.raw or false
  return inst
end

---@class ILUnopParams : ILInstParamsBase
---@field result_reg ILRegister
---@field op AstUnOpOp
---@field right_ptr ILPointer

---@param params ILUnopParams
---@return ILUnop
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
---@return ILLabel
local function new_label(params)
  local inst = new_inst(params, "label")
  inst.name = params.name
  return inst
end

---@class ILJumpParams : ILInstParamsBase
---@field label ILLabel

---@param params ILJumpParams
---@return ILJump
local function new_jump(params)
  local inst = new_inst(params, "jump")
  inst.label = assert_field(params, "label")
  return inst
end

---@class ILTestParams : ILInstParamsBase
---@field label ILLabel
---@field condition_ptr ILPointer
---@field jump_if_true boolean|nil

---@param params ILTestParams
---@return ILTest
local function new_test(params)
  local inst = new_inst(params, "test")
  inst.label = assert_field(params, "label")
  inst.condition_ptr = assert_ptr(params, "condition_ptr")
  inst.jump_if_true = params.jump_if_true or false
  return inst
end

---@class ILCallParams : ILInstParamsBase
---@field func_reg ILRegister
---@field arg_ptrs ILPointer[]|nil @ The last one can be an `ILVarargRegister`
---@field result_regs ILRegister[]|nil @ The last one can be an `ILVarargRegister`

---@param params ILCallParams
---@return ILCall
local function new_call(params)
  local inst = new_inst(params, "call")
  inst.func_reg = assert_reg(params, "func_reg")
  inst.arg_ptrs = params.arg_ptrs or {}
  inst.result_regs = params.result_regs or {}
  return inst
end

---@class ILRetParams : ILInstParamsBase
---@field ptrs ILPointer[]|nil @ The last one can be an `ILVarargRegister`

---@param params ILRetParams
---@return ILRet
local function new_ret(params)
  local inst = new_inst(params, "ret")
  inst.ptrs = params.ptrs or {}
  return inst
end

---@class ILClosureParams : ILInstParamsBase
---@field result_reg ILRegister
---@field func ILFunction

---@param params ILClosureParams
---@return ILClosure
local function new_closure(params)
  local inst = new_inst(params, "closure")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.func = assert_field(params, "func")
  return inst
end

---@class ILVarargParams : ILInstParamsBase
---@field result_regs ILRegister[]|nil @ The last one can be an `ILVarargRegister`

---@param params ILVarargParams
---@return ILVararg
local function new_vararg(params)
  local inst = new_inst(params, "vararg")
  inst.result_regs = params.result_regs or {}
  return inst
end

---@class ILCloseUpParams : ILInstParamsBase
---@field regs ILRegister[]

---@param params ILCloseUpParams
---@return ILCloseUp
local function new_close_up(params)
  local inst = new_inst(params, "close_up")
  inst.regs = params.regs or {}
  return inst
end

---@class ILScopingParams : ILInstParamsBase
---@field regs ILRegister[]

---@param params ILScopingParams
---@return ILScoping
local function new_scoping(params)
  local inst = new_inst(params, "scoping")
  inst.regs = params.regs or {}
  return inst
end

---@class ILToNumberParams : ILInstParamsBase
---@field result_reg ILRegister
---@field right_ptr ILPointer

---@param params ILToNumberParams
---@return ILToNumber
local function new_to_number(params)
  local inst = new_inst(params, "to_number")
  inst.result_reg = assert_reg(params, "result_reg")
  inst.right_ptr = assert_ptr(params, "right_ptr")
  return inst
end

----------------------------------------------------------------------------------------------------
-- pointers
----------------------------------------------------------------------------------------------------

local function new_ptr(ptr_type)
  return {ptr_type = ptr_type}
end

local function new_reg(name)
  ---@type ILRegister
  local ptr = new_ptr("reg")
  ptr.name = name
  ptr.is_vararg = false
  return ptr
end

local gap_reg = new_reg()
gap_reg.is_gap = true

local function new_vararg_reg()
  ---@type ILRegister
  local ptr = new_ptr("reg")
  ptr.is_vararg = true
  return ptr
end

local function new_number(value)
  ---@type ILNumber
  local ptr = new_ptr("number")
  ptr.value = assert(value)
  return ptr
end

local function new_string(value)
  ---@type ILString
  local ptr = new_ptr("string")
  ptr.value = assert(value)
  return ptr
end

local function new_boolean(value)
  ---@type ILBoolean
  local ptr = new_ptr("boolean")
  assert(value ~= nil)
  ptr.value = value
  return ptr
end

local function new_nil()
  ---@type ILNil
  local ptr = new_ptr("nil")
  return ptr
end

----------------------------------------------------------------------------------------------------
-- instruction helpers
----------------------------------------------------------------------------------------------------

local empty = {}

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return boolean
local function is_inst_group(inst_or_group)
  return inst_or_group.group_type--[[@as boolean]]
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILInstruction|ILInstructionGroup
local function get_inst_or_group(inst_or_group)
  return is_inst_group(inst_or_group) and inst_or_group
    or inst_or_group.inst_group or inst_or_group
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILInstruction|ILInstructionGroup?
local function get_prev_inst_or_group(inst_or_group)
  if is_inst_group(inst_or_group) then
    return get_inst_or_group(inst_or_group.start.prev)
  else
    return get_inst_or_group(inst_or_group.prev)
  end
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILInstruction|ILInstructionGroup?
local function get_next_inst_or_group(inst_or_group)
  if is_inst_group(inst_or_group) then
    return get_inst_or_group(inst_or_group.stop.next)
  else
    return get_inst_or_group(inst_or_group.next)
  end
end

---Iterates instructions, but when encountering an instruction which is apart of an instruction group, it
---returns that group instead, followed by the first instruction or group past that group.\
---Effectively seeing instruction groups as single instructions
---@param il_func ILFunction
---@param start_inst_or_group ILInstruction|ILInstructionGroup?
---@param stop_inst_or_group ILInstruction|ILInstructionGroup?
---@return fun(): (ILInstruction|ILInstructionGroup?) iterator
local function iterate_insts_and_groups(il_func, start_inst_or_group, stop_inst_or_group)
  start_inst_or_group = start_inst_or_group or il_func.instructions.first
  stop_inst_or_group = stop_inst_or_group or il_func.instructions.last
  local current_inst_or_group = get_inst_or_group(start_inst_or_group)
  stop_inst_or_group = get_inst_or_group(stop_inst_or_group)
  return function()
    local result = current_inst_or_group
    if current_inst_or_group == stop_inst_or_group then
      current_inst_or_group = (nil)--[[@as ILInstruction|ILInstructionGroup]]
      stop_inst_or_group = nil
      return result
    end
    ---@cast current_inst_or_group -nil
    current_inst_or_group = get_inst_or_group((is_inst_group(current_inst_or_group)
      and current_inst_or_group.stop.next
      or current_inst_or_group.next)--[[@as ILInstruction]])
    return result
  end
end

---@param inst_group ILInstructionGroup
---@return fun(): (ILInstruction?)
local function iterate_insts_in_group(inst_group)
  return ill.iterate(inst_group.start.list, inst_group.start, inst_group.stop)
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILRegister[]
local function get_live_regs(inst_or_group)
  if is_inst_group(inst_or_group) then
    ---@cast inst_or_group ILInstructionGroup
    if inst_or_group.start == inst_or_group.stop then
      util.debug_abort("Hold up, why is there an instruction _group_ with only _one_ instruction?!")
      return inst_or_group.start.live_regs
    end
    return linq(inst_or_group.start.live_regs)
      :union(inst_or_group.stop.live_regs)
      :where(function(reg) return not reg.is_internal end)
      :to_array()
    ;
  else
    return inst_or_group.live_regs
  end
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILRegister[]
local function get_regs_stop_at_list(inst_or_group)
  if is_inst_group(inst_or_group) then
    ---@cast inst_or_group ILInstructionGroup
    return linq(iterate_insts_in_group(inst_or_group))
      :select_many(function(inst) return inst.regs_stop_at_list or empty end)
      :to_array()
    ;
  else
    return inst_or_group.regs_stop_at_list
  end
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return table<ILRegister, true>
local function get_regs_stop_at_lut(inst_or_group)
  if is_inst_group(inst_or_group) then
    ---@cast inst_or_group ILInstructionGroup
    return linq(iterate_insts_in_group(inst_or_group))
      :select_many(function(inst) return inst.regs_stop_at_list or empty end)
      :to_lookup()
    ;
  else
    return inst_or_group.regs_stop_at_lut
  end
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return ILRegister[]
local function get_regs_start_at_list(inst_or_group)
  if is_inst_group(inst_or_group) then
    ---@cast inst_or_group ILInstructionGroup
    return linq(iterate_insts_in_group(inst_or_group))
      :select_many(function(inst) return inst.regs_start_at_list or empty end)
      :to_array()
  else
    return inst_or_group.regs_start_at_list
  end
end

---@param inst_or_group ILInstruction|ILInstructionGroup
---@return table<ILRegister, true>
local function get_regs_start_at_lut(inst_or_group)
  if is_inst_group(inst_or_group) then
    ---@cast inst_or_group ILInstructionGroup
    return linq(iterate_insts_in_group(inst_or_group))
      :select_many(function(inst) return inst.regs_start_at_list or empty end)
      :to_lookup()
  else
    return inst_or_group.regs_start_at_lut
  end
end

----------------------------------------------------------------------------------------------------
-- types
----------------------------------------------------------------------------------------------------

local nil_flag = 1
local boolean_flag = 2
local number_flag = 4
local string_flag = 8
local function_flag = 16
local table_flag = 32
local userdata_flag = 64
local thread_flag = 128
local every_flag = 255

---@class ILTypeParams
---@field type_flags ILTypeFlags
---@field inferred_flags ILTypeFlags

---@param params ILTypeParams
---@return ILType
local function new_type(params)
  params.type_flags = params.type_flags or 0
  params.inferred_flags = params.inferred_flags or 0
  return params--[[@as ILType]]
end

local copy_identity
local copy_identities
local copy_class
local copy_classes
local copy_type
local copy_types
do
  ---@generic T : table?
  ---@param list T
  ---@return T
  local function copy_list(list, copy_func)
    if not list then return nil end
    local result = {}
    for i, value in ipairs(list) do
      result[i] = copy_func(value)
    end
    return result
  end

  function copy_identity(identity)
    return {
      id = identity.id,
      type_flags = identity.type_flags,
    }
    -- TODO: extend this when deciding what data structures are in ILTypeIdentity
  end

  function copy_identities(identities)
    return copy_list(identities, copy_identity)
  end

  function copy_class(class)
    local result = {}
    if class.kvps then
      local kvps = {}
      result.kvps = kvps
      for i, kvp in ipairs(class.kvps) do
        kvps[i] = {
          key_type = copy_type(kvp.key_type),
          value_type = copy_type(kvp.value_type),
        }
      end
    end
    result.metatable = class.metatable and copy_class(class.metatable)
    return result
  end

  ---@generic T : ILClass[]?
  ---@param classes T
  ---@return T
  function copy_classes(classes)
    return copy_list(classes, copy_class)
  end

  function copy_type(type)
    local result = new_type{
      type_flags = type.type_flags,
      inferred_flags = type.inferred_flags,
      number_ranges = type.number_ranges and number_ranges.copy_ranges(type.number_ranges),
      string_ranges = type.string_ranges and number_ranges.copy_ranges(type.string_ranges),
      string_values = util.optional_shallow_copy(type.string_values),
      boolean_value = type.boolean_value,
      function_prototypes = util.optional_shallow_copy(type.function_prototypes),
      light_userdata_prototypes = util.optional_shallow_copy(type.light_userdata_prototypes),
    }
    result.identities = copy_identities(type.identities)
    result.table_classes = copy_classes(type.table_classes)
    result.userdata_classes = copy_classes(type.userdata_classes)
    return result
  end

  function copy_types(types)
    return copy_list(types, copy_type)
  end
end

local identity_list_contains
local identity_list_equal
do
  local function contains_internal(left, right, get_value)
    local lut = {}
    for _, value in ipairs(left) do
      lut[get_value and get_value(value) or value] = true
    end
    for _, value in ipairs(right) do
      value = get_value and get_value(value) or value
      if not lut[value] then
        return false
      end
      lut[value] = nil
    end
    return true, lut
  end

  function identity_list_contains(left, right, get_value)
    if not left then return true end
    return (contains_internal(left, right, get_value))
  end

  function identity_list_equal(left, right, get_value)
    if not left then return not right end
    local result, lut = contains_internal(left, right, get_value)
    return result and not next(lut--[[@as table]])
  end
end

local equals

-- NOTE: classes with key value pairs where multiple of their value types are equal are invalid [...]
-- and will result in this compare function to potentially return false in cases where it shouldn't
local function class_equals(left_class, right_class)
  if left_class.kvps then
    if not right_class.kvps then return false end
    if #left_class.kvps ~= #right_class.kvps then return false end
    local finished_right_index_lut = {}
    for _, left_kvp in ipairs(left_class.kvps) do
      for right_index, right_kvp in ipairs(right_class.kvps) do
        if not finished_right_index_lut[right_index] and equals(left_kvp.key_type, right_kvp.key_type) then
          if not equals(left_kvp.value_type, right_kvp.value_type) then
            return false
          end
          finished_right_index_lut[right_index] = true
          goto found_match
        end
      end
      do return false end
      ::found_match::
    end
  end
  if left_class.metatable then
    if not right_class.metatable then return false end
    return class_equals(left_class.metatable, right_class.metatable)
  end
  return true
end

local function classes_equal(left_classes, right_classes)
  if not left_classes then return not right_classes end
  if #left_classes ~= #right_classes then return false end
  local finished_right_index_lut = {}
  for _, left_class in ipairs(left_classes) do
    for right_index, right_class in ipairs(right_classes) do
      if not finished_right_index_lut[right_index] and class_equals(left_class, right_class) then
        finished_right_index_lut[right_index] = true
        goto found_match
      end
    end
    do return false end
    ::found_match::
  end
  return true
end

do
  ---does not care about `inferred_flags` nor `ILClass.inferred`
  ---@param left_type ILType
  ---@param right_type ILType
  function equals(left_type, right_type)
    local type_flags = left_type.type_flags
    if type_flags ~= right_type.type_flags then
      return false
    end
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value ~= right_type.boolean_value then
        return false
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      if not number_ranges.ranges_equal(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not number_ranges.ranges_equal(left_type.string_ranges, right_type.string_ranges) then
        return false
      end
      if not identity_list_equal(left_type.string_values, right_type.string_values) then
        return false
      end
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      if not identity_list_equal(left_type.function_prototypes, right_type.function_prototypes) then
        return false
      end
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      if not classes_equal(left_type.table_classes, right_type.table_classes) then
        return false
      end
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      if not identity_list_equal(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      ) then
        return false
      end
      if not classes_equal(left_type.userdata_classes, right_type.userdata_classes) then
        return false
      end
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end

    if not identity_list_equal(
      left_type.identities,
      right_type.identities,
      function(value) return value.id end
    ) then
      return false
    end

    return true
  end
end

local union
do
  local function get_types_to_combine(left_type, right_type, flag)
    local left_has_flag = bit32.band(left_type.type_flags, flag)
    local right_has_flag = bit32.band(right_type.type_flags, flag)
    if left_has_flag and right_has_flag then
      return nil, true
    end
    if left_has_flag then
      return left_type
    end
    if right_has_flag then
      return right_type
    end
  end

  local function shallow_list_union(left_list, right_list)
    -- if one of them is nil the result will also be nil
    if not left_list or not right_list then return nil end
    local lut = {}
    local result = {}
    for i, value in ipairs(left_list) do
      lut[value] = true
      result[i] = value
    end
    for _, value in ipairs(right_list) do
      if not lut[value] then
        result[#result+1] = value
      end
    end
    return result
  end

  ---@param left_classes ILClass[]?
  ---@param right_classes ILClass[]?
  local function union_classes(left_classes, right_classes)
    -- if one of them is nil the result will also be nil
    if not left_classes or not right_classes then return nil end
    local result = copy_classes(left_classes)
    local visited_left_index_lut = {}
    for _, right_class in ipairs(right_classes) do
      for left_index = 1, #left_classes do
        if not visited_left_index_lut[left_index] and class_equals(left_classes[left_index], right_class) then
          visited_left_index_lut[left_index] = true
          goto found_match
        end
      end
      result[#result+1] = copy_class(right_class)
      ::found_match::
    end
    return result
  end

  -- NOTE: very similar to shallow_list_union, just id comparison is different
  local function identities_union(left_identities, right_identities)
    -- if one of them is nil the result will also be nil
    if not left_identities or not right_identities then return nil end
    local lut = {}
    local result = {}
    for i, id in ipairs(left_identities) do
      lut[id.id] = true
      result[i] = id
    end
    for _, id in ipairs(right_identities) do
      -- TODO: if it finds the id in the lut it should probably create a union of the respective instance data
      if not lut[id.id] then
        result[#result+1] = id
      end
    end
    return result
  end

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  function union(left_type, right_type)
    local result = new_type{
      type_flags = bit32.bor(left_type.type_flags, right_type.type_flags),
      inferred_flags = bit32.bor(left_type.inferred_flags, right_type.inferred_flags),
    }
    local base, do_merge
    base, do_merge = get_types_to_combine(left_type, right_type, nil_flag)
    if do_merge then
    elseif base then
    end
    base, do_merge = get_types_to_combine(left_type, right_type, boolean_flag)
    if do_merge then
      if left_type.boolean_value == right_type.boolean_value then
        result.boolean_value = left_type.boolean_value
      else
        result.boolean_value = nil
      end
    elseif base then
      result.boolean_value = base.boolean_value
    end
    base, do_merge = get_types_to_combine(left_type, right_type, number_flag)
    if do_merge then
      result.number_ranges = number_ranges.union_ranges(left_type.number_ranges, right_type.number_ranges)
    elseif base then
      result.number_ranges = number_ranges.copy_ranges(base.number_ranges)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, string_flag)
    if do_merge then
      result.string_ranges = number_ranges.union_ranges(left_type.string_ranges, right_type.string_ranges)
      result.string_values = shallow_list_union(left_type.string_values, right_type.string_values)
    elseif base then
      result.string_ranges = number_ranges.copy_ranges(base.string_ranges)
      result.string_values = util.optional_shallow_copy(base.string_values)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, function_flag)
    if do_merge then
      result.function_prototypes = shallow_list_union(
        left_type.function_prototypes,
        right_type.function_prototypes
      )
    elseif base then
      result.function_prototypes = util.optional_shallow_copy(base.function_prototypes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, table_flag)
    if do_merge then
      result.table_classes = union_classes(left_type.table_classes, right_type.table_classes)
    elseif base then
      result.table_classes = copy_classes(base.table_classes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, userdata_flag)
    if do_merge then
      result.light_userdata_prototypes = shallow_list_union(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      )
      result.userdata_classes = union_classes(left_type.userdata_classes, right_type.userdata_classes)
    elseif base then
      result.light_userdata_prototypes = util.optional_shallow_copy(base.light_userdata_prototypes)
      result.userdata_classes = copy_classes(base.userdata_classes)
    end
    base, do_merge = get_types_to_combine(left_type, right_type, thread_flag)
    if do_merge then
    elseif base then
    end

    result.identities = identities_union(left_type.identities, right_type.identities)

    return result
  end
end

local intersect
do
  local function shallow_list_intersect(left_list, right_list)
    if not left_list then
      if not right_list then
        return nil
      else
        return util.shallow_copy(right_list)
      end
    elseif not right_list then
      return util.shallow_copy(left_list)
    else
      local value_lut = {}
      for _, value in ipairs(left_list) do
        value_lut[value] = true
      end
      local string_values = {}
      for _, value in ipairs(right_list) do
        if value_lut[value] then
          string_values[#string_values+1] = value
        end
      end
      return string_values
    end
  end

  local function ranges_intersect(left_ranges, right_ranges)
    if not left_ranges then
      if not right_ranges then
        return nil
      end
      return number_ranges.copy_ranges(right_ranges)
    elseif not right_ranges then
      return number_ranges.copy_ranges(left_ranges)
    end
    return number_ranges.intersect_ranges(left_ranges, right_ranges)
  end

  local function classes_intersect(left_classes, right_classes)
    if not left_classes then
      if not right_classes then
        return nil
      else
        return copy_classes(right_classes)
      end
    elseif not right_classes then
      return copy_classes(left_classes)
    end
    local finished_right_index_lut = {}
    local result = {}
    for _, left_class in ipairs(left_classes) do
      for right_index, right_class in ipairs(right_classes) do
        if not finished_right_index_lut[right_index] and class_equals(left_class, right_class) then
          finished_right_index_lut[right_index] = true
          result[#result+1] = copy_class(left_class)
          break
        end
      end
    end
    return result
  end

  -- NOTE: very similar to shallow_list_union, just copying and id comparison is different
  local function identities_intersect(left_identities, right_identities)
    if not left_identities then
      if not right_identities then
        return nil
      else
        return copy_identities(right_identities)
      end
    elseif not right_identities then
      return copy_identities(left_identities)
    else
      local id_lut = {}
      for _, id in ipairs(left_identities) do
        id_lut[id.id] = true
      end
      local result = {}
      for _, id in ipairs(right_identities) do
        if id_lut[id.id] then
          result[#result+1] = id
        end
      end
      return result
    end
  end

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  function intersect(left_type, right_type)
    local result = new_type{
      type_flags = bit32.band(left_type.type_flags, right_type.type_flags),
      inferred_flags = bit32.band(left_type.inferred_flags, right_type.inferred_flags),
    }
    local type_flags = result.type_flags
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value == right_type.boolean_value then
        result.boolean_value = left_type.boolean_value
      elseif left_type.boolean_value == nil then
        result.boolean_value = right_type.boolean_value
      elseif right_type.boolean_value == nil then
        result.boolean_value = left_type.boolean_value
      else
        result.type_flags = bit32.bxor(result.type_flags, boolean_flag)
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      result.number_ranges = ranges_intersect(left_type.number_ranges, right_type.number_ranges)
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      result.string_ranges = ranges_intersect(left_type.string_ranges, right_type.string_ranges)
      result.string_values = shallow_list_intersect(left_type.string_values, right_type.string_values)
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      result.function_prototypes = shallow_list_intersect(
        left_type.function_prototypes,
        right_type.function_prototypes
      )
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      result.table_classes = classes_intersect(left_type.table_classes, right_type.table_classes)
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      result.light_userdata_prototypes = shallow_list_intersect(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      )
      result.userdata_classes = classes_intersect(left_type.userdata_classes, right_type.userdata_classes)
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end
    result.identities = identities_intersect(left_type.identities, right_type.identities)
    return result
  end
end

local contains
do
  local function contains_classes(left_classes, right_classes)
    if not right_classes then return not left_classes end
    if #left_classes < #right_classes then return false end
    local finished_left_index_lut = {}
    for _, right_class in ipairs(right_classes) do
      for left_index, left_class in ipairs(left_classes) do
        if not finished_left_index_lut[left_index] and class_equals(left_class, right_class) then
          finished_left_index_lut[left_index] = true
          goto found_match
        end
      end
      do return false end
      ::found_match::
    end
    return true
  end

  ---does not care about `inferred_flags` nor `ILClass.inferred`
  function contains(left_type, right_type)
    local type_flags = right_type.type_flags
    -- do the right flags contain flags that the left flags don't?
    if bit32.band(bit32.bnot(left_type.type_flags), type_flags) ~= 0 then
      return false
    end
    if bit32.band(type_flags, nil_flag) ~= 0 then
      -- nothing to do
    end
    if bit32.band(type_flags, boolean_flag) ~= 0 then
      if left_type.boolean_value ~= nil and left_type.boolean_value ~= right_type.boolean_value then
        return false
      end
    end
    if bit32.band(type_flags, number_flag) ~= 0 then
      if not number_ranges.contains_ranges(left_type.number_ranges, right_type.number_ranges) then
        return false
      end
    end
    if bit32.band(type_flags, string_flag) ~= 0 then
      if not number_ranges.contains_ranges(left_type.string_ranges, right_type.string_ranges) then
        return false
      end
      if not identity_list_contains(left_type.string_values, right_type.string_values) then
        return false
      end
    end
    if bit32.band(type_flags, function_flag) ~= 0 then
      if not identity_list_contains(left_type.function_prototypes, right_type.function_prototypes) then
        return false
      end
    end
    if bit32.band(type_flags, table_flag) ~= 0 then
      if not contains_classes(left_type.table_classes, right_type.table_classes) then
        return false
      end
    end
    if bit32.band(type_flags, userdata_flag) ~= 0 then
      if not identity_list_contains(
        left_type.light_userdata_prototypes,
        right_type.light_userdata_prototypes
      ) then
        return false
      end
      if not contains_classes(left_type.userdata_classes, right_type.userdata_classes) then
        return false
      end
    end
    if bit32.band(type_flags, thread_flag) ~= 0 then
    end

    if not identity_list_contains(
      left_type.identities,
      right_type.identities,
      function(value) return value.id end
    ) then
      return false
    end

    return true
  end
end

local exclude
do
  ---@generic T
  ---@param base_list T[]?
  ---@param other_list T[]?
  ---@return T[]?
  local function list_exclude(base_list, other_list)
    if not other_list then return nil end
    if not base_list then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local id_lut = {}
    for _, value in ipairs(other_list) do
      id_lut[value] = true
    end
    local result = {}
    for _, value in ipairs(base_list) do
      if not id_lut[value] then
        result[#result+1] = value
      end
    end
    return result
  end

  ---@param base_identities ILTypeIdentity[]?
  ---@param other_identities ILTypeIdentity[]?
  local function identity_list_exclude(base_identities, other_identities)
    if not other_identities then return nil end
    if not base_identities then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local id_lut = {}
    for _, id in ipairs(other_identities) do
      id_lut[id.id] = true
    end
    local result = {}
    for _, id in ipairs(base_identities) do
      if not id_lut[id.id] then
        result[#result+1] = id
      end
    end
    return result
  end

  ---@param base_classes ILClass[]?
  ---@param other_classes ILClass[]?
  local function exclude_classes(base_classes, other_classes)
    if not other_classes then return nil end
    if not base_classes then
      -- NOTE: the type system cannot represent an inverted set of values
      return nil
    end
    local result = {}
    -- every left side that isn't found on the right side needs to be kept
    local visited_other_index_lut = {}
    for _, base_class in ipairs(base_classes) do
      for other_index = 1, #other_classes do
        if not visited_other_index_lut[other_index] and class_equals(base_class, other_classes[other_index]) then
          visited_other_index_lut[other_index] = true
          goto found_match
        end
      end
      result[#result+1] = copy_class(base_class)
      ::found_match::
    end
    return result
  end

  local everything_ranges = {number_ranges.inclusive(-1/0), number_ranges.range_type.everything}

  ---TODO: doesn't handle `ILClass.inferred` properly because the data structure doesn't support it. [...]
  ---what should happen is that a class can be flagged as both inferred and not inferred at the same time [...]
  ---without the class being in the list of classes twice
  ---@param base_type ILType
  ---@param other_type ILType
  ---@return ILType
  function exclude(base_type, other_type)
    -- TODO: how to handle excluding an inferred type from a non inferred type?
    local result = new_type{type_flags = base_type.type_flags, inferred_flags = base_type.inferred_flags}
    local type_flags_to_check = bit32.band(base_type.type_flags, other_type.type_flags)
    if bit32.band(type_flags_to_check, nil_flag) ~= 0 then
      result.type_flags = result.type_flags - nil_flag
    end
    if bit32.band(type_flags_to_check, boolean_flag) ~= 0 then
      if other_type.boolean_value == nil or base_type.boolean_value == other_type.boolean_value then
        result.type_flags = result.type_flags - boolean_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(boolean_flag))
      else
        result.boolean_value = base_type.boolean_value
      end
    end
    if bit32.band(type_flags_to_check, number_flag) ~= 0 then
      local base_ranges = base_type.number_ranges or everything_ranges
      local other_ranges = base_type.number_ranges or everything_ranges
      local result_number_ranges = number_ranges.exclude_ranges(base_ranges, other_ranges)
      if number_ranges.is_empty(result_number_ranges) then
        result.type_flags = result.type_flags - number_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(number_flag))
      else
        result.number_ranges = result_number_ranges
      end
    end
    if bit32.band(type_flags_to_check, string_flag) ~= 0 then
      local base_ranges = base_type.string_ranges or everything_ranges
      local other_ranges = base_type.string_ranges or everything_ranges
      local string_ranges = number_ranges.exclude_ranges(base_ranges, other_ranges)
      local string_values = list_exclude(base_type.string_values, other_type.string_values)
      if number_ranges.is_empty(string_ranges)
        and string_values and not string_values[1]
      then
        result.type_flags = result.type_flags - string_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(string_flag))
      else
        result.string_ranges = string_ranges
        result.string_values = string_values
      end
    end
    if bit32.band(type_flags_to_check, function_flag) ~= 0 then
      local function_prototypes = list_exclude(base_type.function_prototypes, other_type.function_prototypes)
      if function_prototypes and not function_prototypes[1] then
        result.type_flags = result.type_flags - function_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(function_flag))
      else
        result.function_prototypes = function_prototypes
      end
    end
    if bit32.band(type_flags_to_check, table_flag) ~= 0 then
      local table_classes = exclude_classes(base_type.table_classes, other_type.table_classes)
      if table_classes and not table_classes[1] then
        result.type_flags = result.type_flags - table_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(table_flag))
      else
        result.table_classes = table_classes
      end
    end
    if bit32.band(type_flags_to_check, userdata_flag) ~= 0 then
      local userdata_classes = exclude_classes(base_type.userdata_classes, other_type.userdata_classes)
      local light_userdata_prototypes = list_exclude(
        base_type.light_userdata_prototypes,
        other_type.light_userdata_prototypes
      )
      if userdata_classes and not userdata_classes[1]
        and light_userdata_prototypes and not light_userdata_prototypes[1]
      then
        result.type_flags = result.type_flags - userdata_flag
        result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(userdata_flag))
      else
        result.userdata_classes = userdata_classes
        result.light_userdata_prototypes = light_userdata_prototypes
      end
    end
    if bit32.band(type_flags_to_check, thread_flag) ~= 0 then
      result.type_flags = result.type_flags - thread_flag
      result.inferred_flags = bit32.band(result.inferred_flags, bit32.bnot(thread_flag))
    end
    result.identities = identity_list_exclude(base_type.identities, other_type.identities)
    return result
  end
end

local function has_all_flags(type_flags, other_flags)
  return bit32.band(type_flags, other_flags) == other_flags
end

local function has_any_flags(type_flags, other_flags)
  return bit32.band(type_flags, other_flags) ~= 0
end

-- TODO: range utilities

local invalid_index_base_flags = nil_flag + boolean_flag + number_flag + function_flag + thread_flag

local type_indexing
local class_indexing
do
  local __index_key_type = new_type{
    type_flags = string_flag,
    string_ranges = {number_ranges.inclusive(-1/0)},
    string_values = {"__index"},
  }

  function class_indexing(class, index_type, do_rawget)
    local result_type = new_type{type_flags = 0}
    if class.kvps then
      for _, kvp in ipairs(class.kvps) do
        local overlap_key_type = intersect(kvp.key_type, index_type)
        if overlap_key_type.type_flags ~= 0 then
          result_type = union(result_type, overlap_key_type)
          result_type = union(result_type, kvp.value_type)
        end
      end
    end
    if not equals(result_type, index_type) then
      if not do_rawget and class.metatable then
        local __index_value_type = class_indexing(class.metatable, __index_key_type, true)
        local value_type_flags = __index_value_type.type_flags
        if has_all_flags(value_type_flags, nil_flag) then
          result_type = union(result_type, new_type{type_flags = nil_flag})
        end
        if has_all_flags(value_type_flags, table_flag) then
          result_type = union(result_type, type_indexing(__index_value_type, index_type))
        end
        if has_all_flags(value_type_flags, function_flag) then
          util.debug_print("-- TODO: validate `__index` function signatures and use function return types.")
          -- TODO: this function call could modify the entire current state which must be tracked somehow
        end
        if has_any_flags(value_type_flags, bit32.bnot(nil_flag + table_flag + function_flag)) then
          util.debug_print("-- TODO: probably warn about invalid `__index` value type.")
        end
      else
        result_type = union(result_type, new_type{type_flags = nil_flag})
      end
    end
    return result_type
  end

  function type_indexing(base_type, index_type, do_rawget)
    local err
    do
      local invalid_flags = bit32.band(base_type.type_flags, invalid_index_base_flags)
      if invalid_flags ~= 0 then
        err = error_code_util.new_error_code{
          error_code = error_code_util.codes.ts_invalid_index_base_type,
          message_args = {string.format("%x", invalid_flags)}, -- TODO: format flags as a meaningful string
        }
      end
    end
    local result_type = new_type{type_flags = 0}
    if bit32.band(base_type.type_flags, string_flag) then
      util.debug_print("-- TODO: add inbuilt string library function(s) to result type.")
    end
    if bit32.band(base_type.type_flags, table_flag) ~= 0 then
      if not base_type.table_classes then
        return new_type{type_flags = every_flag}, err
      end
      result_type = union(result_type, class_indexing(base_type.table_classes, index_type, do_rawget))
    end
    if bit32.band(base_type.type_flags, userdata_flag) ~= 0 then
      -- TODO: how to detect light userdata? indexing into light userdata is an error to my knowledge
      if not base_type.userdata_classes then
        return new_type{type_flags = every_flag}, err
      end
      result_type = union(result_type, class_indexing(base_type.userdata_classes, index_type, do_rawget))
    end
    if result_type.type_flags == 0 then -- default to nil, because that's how indexing works
      result_type.type_flags = nil_flag
    end
    return result_type, err
  end
end

local type_new_indexing
local class_new_indexing
do
  local __newindex_key_type = new_type{
    type_flags = string_flag,
    string_ranges = {number_ranges.inclusive(-1/0)},
    string_values = {"__newindex"},
  }

  ---@param classes ILClass[]
  ---@param key_type ILType
  ---@param value_type ILType
  ---@param do_rawset boolean
  function class_new_indexing(classes, key_type, value_type, do_rawset)
    for _, class in ipairs(classes) do
      if class.inferred then
        -- TODO: add the key_type and value_type to the class
      else
        local found_key_type = new_type{type_flags = 0}
        for _, kvp in ipairs(class.kvps) do -- TODO: handle nil kvps
          local overlap = intersect(key_type, kvp.key_type)
          if overlap.type_flags ~= 0 then
            if not contains(kvp.value_type, value_type) then
              util.debug_print("-- TODO: warn about assigning invalid value_type")
            end
            found_key_type = union(found_key_type, overlap)
            if equals(found_key_type, key_type) then
              goto found_whole_key_type
            end
          end
        end
        if not do_rawset and class.metatable then
          local __newindex_value_type = class_indexing(class.metatable, __newindex_key_type, true)
          local value_type_flags = __newindex_value_type.type_flags
          if has_all_flags(value_type_flags, function_flag) then
            util.debug_print("-- TODO: validate `__newindex` function signatures.")
            -- TODO: this function call could modify the entire current state which must be tracked somehow
            goto found_whole_key_type
          end
          if has_any_flags(value_type_flags, bit32.bnot(function_flag)) then
            util.debug_print("-- TODO: probably warn about invalid `__newindex` value type.")
          end
        end
        util.debug_print("-- TODO: warn about assigning using invalid key_type")
        ::found_whole_key_type::
      end
    end
  end

  function type_new_indexing(base_type, key_type, value_type, do_rawset)
    local err
    do
      local invalid_flags = bit32.band(base_type.type_flags, invalid_index_base_flags)
      if invalid_flags ~= 0 then
        err = error_code_util.new_error_code{
          error_code = error_code_util.codes.ts_invalid_index_base_type,
          message_args = {string.format("%x", invalid_flags)}, -- TODO: format flags as a meaningful string
        }
      end
    end
    if bit32.band(base_type.type_flags, string_flag) then
      util.debug_print("-- TODO: new index into strings might be possible with a '__newindex', \z
        but it's a really dumb thing to do so this should probably warn regardless. To handle it \z
        properly we need an understanding of globals to check if '_ENV.string` has a '__newindex'."
      )
    end
    local result_type = copy_type(base_type)
    if bit32.band(base_type.type_flags, table_flag) ~= 0 then
      if base_type.table_classes then
        class_new_indexing(result_type.table_classes, key_type, value_type, do_rawset)
      end
    end
    if bit32.band(base_type.type_flags, userdata_flag) ~= 0 then
      if do_rawset and not base_type.userdata_classes or base_type.userdata_classes[1] then
        util.debug_print("-- TODO: rawset on a userdata class is an error I'm pretty sure.")
      end
      -- TODO: how to detect light userdata? indexing into light userdata is an error to my knowledge
      if not do_rawset and base_type.userdata_classes then
        class_new_indexing(result_type.userdata_classes, key_type, value_type, false)
      end
    end
    return result_type
  end
end

----------------------------------------------------------------------------------------------------
-- il blocks
----------------------------------------------------------------------------------------------------

-- TODO: either add a function or change normalize_blocks to handle changing the jump target of tests/jumps
-- (since that change the links between blocks)
-- TODO: add a function to handle removal of instructions, potentially merging or removing blocks

local function new_block(start_inst, stop_inst)
  return {
    source_links = {},
    start_inst = start_inst,
    stop_inst = stop_inst,
    target_links = {},
  }
end

local function create_link(source_block, target_block)
  local link = {
    source_block = source_block,
    target_block = target_block,
    -- backwards jumps are 99% of the time a loop
    -- I'm not sure how to detect if it is a loop otherwise, but since this is 99% of the time correct
    -- it's good enough. Besides, a jump being marked as a loop even though it isn't doesn't cause harm
    -- while a jump that is a loop not being marked as a loop does cause harm
    is_loop = target_block.start_inst.index < source_block.start_inst.index,
  }
  source_block.target_links[#source_block.target_links+1] = link
  target_block.source_links[#target_block.source_links+1] = link
  return link
end

local function create_links_for_block(block)
  local last_inst = block.stop_inst
  local function assert_next()
    util.debug_assert(last_inst.next, "The next instruction of the last instruction of a block \z
      where the last instruction in the block is not a 'ret' or 'jump' instruction should be \z
      impossible to be nil."
    )
  end
  local inst_type = last_inst.inst_type
  if inst_type == "jump" then
    create_link(block, last_inst.label.block)
  elseif inst_type == "test" then
    assert_next()
    create_link(block, last_inst.next.block)
    create_link(block, last_inst.label.block)
  elseif inst_type == "ret" then
    -- doesn't link to anything
  else -- anything else just continues to the next block
    assert_next()
    create_link(block, last_inst.next.block)
  end
end

local block_ends = util.invert{"jump", "test", "ret"}
---@param func ILFunction
---@param inst ILInstruction
local function normalize_blocks_for_inst(func, inst)
  -- determine if we can connect with the block of the previous instruction
  local can_use_prev_block = inst.prev and not block_ends[inst.prev.inst_type] and inst.inst_type ~= "label"
  -- determine if we can connect with the block of the next instruction
  local can_use_next_block = inst.next and not block_ends[inst.inst_type] and inst.next.inst_type ~= "label"
  -- determine if we have to split a block due to this insertion
  if can_use_prev_block then
    inst.block = inst.prev.block
    if inst.block.stop_inst == inst.prev then
      inst.block.stop_inst = inst
    end
    return
  end
  if can_use_next_block then
    inst.block = inst.next.block
    inst.block.start_inst = inst
    return
  end
  -- can't use either of them, create new block
  local block = new_block(inst, inst)
  inst.block = block
  ill.insert_after(func.blocks, inst.prev and inst.prev.block, block)
  -- deal with source_links
  if inst.prev then
    if inst.prev.inst_type ~= "jump" and inst.prev.inst_type ~= "ret" then
      local prev_link_to_next = inst.prev.block.target_links[1]
      prev_link_to_next.target_block = block
      -- `next` is guaranteed to exist because `create_links_for_block`
      -- asserts as much during the creation of blocks
      local next_source_links = inst.next.block.source_links
      for i = 1, #next_source_links do
        if next_source_links[i] == prev_link_to_next then
          next_source_links[i] = next_source_links[#next_source_links]
          next_source_links[#next_source_links] = nil
          break
        end
      end
    end
  else -- `not inst.prev`
    block.is_main_entry_block = true
    if inst.next then
      inst.next.block.is_main_entry_block = nil
    end
  end
  create_links_for_block(block)
end

----------------------------------------------------------------------------------------------------
-- il registers
----------------------------------------------------------------------------------------------------

---@param regs ILRegister[]
local function is_vararg_list(regs)
  return regs[#regs].is_vararg
end

local visit_regs_for_inst
local visit_all_regs
local inst_uses_reg
local get_flag = 1
local set_flag = 2
local get_and_set_flags = 3
do
  local get = get_flag
  local set = set_flag
  local get_and_set = get_and_set_flags

  local visit_reg

  local function visit_reg_list(data, inst, regs, get_set)
    for _, reg in ipairs(regs) do
      visit_reg(data, inst, reg, get_set)
    end
  end

  local function visit_ptr(data, inst, ptr, get_set)
    if ptr.ptr_type == "reg" then
      visit_reg(data, inst, ptr, get_set)
    end
  end

  local function visit_ptr_list(data, inst, ptrs, get_set)
    for _, ptr in ipairs(ptrs) do
      visit_ptr(data, inst, ptr, get_set)
    end
  end

  local visitor_lut = {
    ["move"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
      visit_ptr(data, inst, inst.right_ptr, get)
    end,
    ["get_upval"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
    end,
    ["set_upval"] = function(data, inst)
      visit_ptr(data, inst, inst.right_ptr, get)
    end,
    ["get_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
      visit_reg(data, inst, inst.table_reg, get)
      visit_ptr(data, inst, inst.key_ptr, get)
    end,
    ["set_table"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg, get)
      visit_ptr(data, inst, inst.key_ptr, get)
      visit_ptr(data, inst, inst.right_ptr, get)
    end,
    ["set_list"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg, get)
      visit_ptr_list(data, inst, inst.right_ptrs, get) -- must be in order
    end,
    ["new_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack
    end,
    ["concat"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack
      visit_ptr_list(data, inst, inst.right_ptrs, get) -- must be in order right above result_reg
    end,
    ["binop"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
      visit_ptr(data, inst, inst.left_ptr, get)
      visit_ptr(data, inst, inst.right_ptr, get)
    end,
    ["unop"] = function(data, inst)
      visit_ptr(data, inst, inst.result_reg, set)
      visit_ptr(data, inst, inst.right_ptr, get)
    end,
    ["label"] = function(data, inst)
    end,
    ["jump"] = function(data, inst)
    end,
    ["test"] = function(data, inst)
      visit_ptr(data, inst, inst.condition_ptr, get)
    end,
    ["call"] = function(data, inst)
      visit_reg(data, inst, inst.func_reg, get)
      visit_ptr_list(data, inst, inst.arg_ptrs, get) -- must be in order right above func_reg
      visit_reg_list(data, inst, inst.result_regs, set) -- must be in order right above func_reg
    end,
    ["ret"] = function(data, inst)
      visit_ptr_list(data, inst, inst.ptrs, get) -- must be in order
    end,
    ---@param inst ILClosure
    ["closure"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack
      for _, upval in ipairs(inst.func.upvals) do
        if upval.parent_type == "local" then
          visit_reg(data, inst, upval.reg_in_parent_func, get)
        end
      end
    end,
    ["vararg"] = function(data, inst)
      visit_reg_list(data, inst, inst.result_regs, set) -- must be in order
    end,
    ["close_up"] = function(data, inst)
      -- this neither gets or sets those registers, but I guess get is more accurate. Not sure to be honest
      visit_reg_list(data, inst, inst.regs, get)
    end,
    ["scoping"] = function(data, inst)
      visit_reg_list(data, inst, inst.regs, get_and_set)
    end,
    ["to_number"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
      visit_reg(data, inst, inst.right_ptr, get)
    end,
  }

  -- ---@param visit_ptr fun(data: T, inst: ILInstruction, ptr: ILPointer, get_set: 1|2|3)

  ---@generic T
  ---@param data T
  ---@param inst ILInstruction
  ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
  function visit_regs_for_inst(data, inst, visit_reg_func)
    visit_reg = visit_reg_func
    visitor_lut[inst.inst_type](data, inst)
  end

  ---@generic T
  ---@param data T
  ---@param func ILFunction
  ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
  function visit_all_regs(data, func, visit_reg_func)
    visit_reg = visit_reg_func
    local inst = func.instructions.first
    while inst do
      visitor_lut[inst.inst_type](data, inst)
      inst = inst.next
    end
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  function inst_uses_reg(inst, reg)
    local result = false
    visit_reg = function(_, _, current_reg, _)
      if current_reg == reg then
        result = true
      end
    end
    visitor_lut[inst.inst_type](nil, inst)
    return result
  end
end

local eval_start_stop_for_all_regs
do
  local function visit_reg(data, inst, reg)
    if not reg.start_at then
      reg.start_at = inst
      data.all_regs[#data.all_regs+1] = reg
    end
    reg.stop_at = inst
  end

  function eval_start_stop_for_all_regs(data)
    if data.func.has_start_stop_insts then return end
    data.all_regs = {}
    local inst = data.func.instructions.first
    while inst do
      visit_regs_for_inst(data, inst, visit_reg)
      inst = inst.next
    end
    data.func.has_start_stop_insts = true
  end
end

local add_start_stop_and_liveliness_for_reg_for_inst
local eval_start_stop_and_liveliness_for_regs_for_inst
do
  ---@param func ILFunction
  ---@param inst ILInstruction
  ---@param reg ILRegister
  function add_start_stop_and_liveliness_for_reg_for_inst(func, inst, reg)
    if func.has_reg_liveliness then
      -- initialize `live_regs` if they are nil. updating others is handled afterwards
      if not inst.live_regs then
        local prev_inst = inst.prev
        if prev_inst then
          local live_regs = util.shallow_copy(prev_inst.live_regs)
          for i = #live_regs, 1, -1 do
            if prev_inst.regs_stop_at_lut and prev_inst.regs_stop_at_lut[live_regs[i]] then
              table.remove(live_regs, i)
            end
          end
          live_regs[#live_regs+1] = reg
          inst.live_regs = live_regs
        else
          inst.live_regs = {reg}
        end
      end
    end

    ---@param start_inst ILInstruction @ inclusive
    ---@param stop_inst ILInstruction @ exclusive
    local function add_to_live_regs(start_inst, stop_inst)
      while start_inst ~= stop_inst do
        start_inst.live_regs[#start_inst.live_regs+1] = reg
        start_inst = start_inst.next
      end
    end

    if not reg.start_at or inst.index < reg.start_at.index then
      if func.has_reg_liveliness then
        if reg.start_at then
          util.remove_from_array(reg.start_at.regs_start_at_list, reg)
          reg.start_at.regs_start_at_lut[reg] = nil
          add_to_live_regs(inst.next, reg.start_at)
        end
        inst.regs_start_at_list = inst.regs_start_at_list or {}
        inst.regs_start_at_list[#inst.regs_start_at_list+1] = reg
        inst.regs_start_at_lut = inst.regs_start_at_lut or {}
        inst.regs_start_at_lut[reg] = true
      end
      reg.start_at = inst
    end

    if not reg.stop_at or inst.index > reg.stop_at.index then
      if func.has_reg_liveliness then
        if reg.stop_at then
          util.remove_from_array(reg.stop_at.regs_stop_at_list, reg)
          reg.stop_at.regs_stop_at_lut[reg] = nil
          add_to_live_regs(reg.stop_at.next, inst)
        end
        inst.regs_stop_at_list = inst.regs_stop_at_list or {}
        inst.regs_stop_at_list[#inst.regs_stop_at_list+1] = reg
        inst.regs_stop_at_lut = inst.regs_stop_at_lut or {}
        inst.regs_stop_at_lut[reg] = true
      end
      reg.stop_at = inst
    end

    -- TODO: pre_state
    -- TODO: post_state
  end

  ---@param func ILFunction
  ---@param inst ILInstruction
  function eval_start_stop_and_liveliness_for_regs_for_inst(func, inst)
    visit_regs_for_inst(func, inst, add_start_stop_and_liveliness_for_reg_for_inst)
  end
end

local remove_start_stop_and_liveliness_for_reg_for_inst
do
  ---@param func ILFunction
  ---@param inst ILInstruction
  ---@param reg ILRegister
  function remove_start_stop_and_liveliness_for_reg_for_inst(func, inst, reg)
    local function do_stuff(iteration_key, start_stop_at_key, list_key, lut_key, end_iteration_inst)
      if inst ~= reg[start_stop_at_key] then return end
      if func.has_reg_liveliness then
        inst[lut_key][reg] = nil
        util.remove_from_array(inst[list_key], reg)
      end
      local current_inst = inst
      while not inst_uses_reg(current_inst, reg) do
        if func.has_reg_liveliness then
          util.remove_from_array(current_inst.live_regs, reg)
        end
        current_inst = current_inst[iteration_key]
        if current_inst == end_iteration_inst then -- only used in the first call to this function
          util.debug_assert(end_iteration_inst, "Impossible because there must be an instruction using this register.")
          if func.has_reg_liveliness then
            reg.stop_at.regs_stop_at_lut[reg] = nil
            util.remove_from_array(reg.stop_at.regs_stop_at_list, reg)
          end
          -- the register is no longer used at all, we are done
          return true
        end
      end
      ---@cast current_inst -nil
      if func.has_reg_liveliness then
        current_inst[lut_key] = current_inst[lut_key] or {}
        current_inst[lut_key][reg] = true
        current_inst[list_key] = current_inst[list_key] or {}
        current_inst[list_key][#current_inst[list_key]+1] = reg
      end
      reg[start_stop_at_key] = current_inst
    end

    if do_stuff("next", "start_at", "regs_start_at_list", "regs_start_at_lut", reg.stop_at) then return end
    do_stuff("prev", "stop_at", "regs_stop_at_list", "regs_stop_at_lut", nil)
  end
end

local eval_live_regs
do
  function eval_live_regs(data)
    if data.func.has_reg_liveliness then return end

    if not data.func.has_start_stop_insts then
      eval_start_stop_for_all_regs(data)
    end

    -- data.all_regs is also populated by `eval_start_stop_for_all_regs`
    if not data.all_regs then
      data.all_regs = {}
      ---@diagnostic disable-next-line: redefined-local
      visit_all_regs(data, data.func, function(data, _, reg)
        data.all_regs[#data.all_regs+1] = reg
      end)
    end

    local start_at_list_lut = {}
    local start_at_lut_lut = {}
    local stop_at_list_lut = {}
    local stop_at_lut_lut = {}
    for _, reg in ipairs(data.all_regs) do
      local list = start_at_list_lut[reg.start_at]
      local lut
      if not list then
        list = {}
        start_at_list_lut[reg.start_at] = list
        lut = {}
        start_at_lut_lut[reg.start_at] = lut
      else
        lut = start_at_lut_lut[reg.start_at]
      end
      list[#list+1] = reg
      lut[reg] = true
      -- copy paste
      list = stop_at_list_lut[reg.stop_at]
      if not list then
        list = {}
        stop_at_list_lut[reg.stop_at] = list
        lut = {}
        stop_at_lut_lut[reg.stop_at] = lut
      else
        lut = stop_at_lut_lut[reg.stop_at]
      end
      list[#list+1] = reg
      lut[reg] = true
    end

    local live_regs = {}
    local inst = data.func.instructions.first
    while inst do
      inst.live_regs = live_regs
      -- starting at this instruction, add them to live_regs for this instruction
      local list = start_at_list_lut[inst]
      if list then
        inst.regs_start_at_list = list
        inst.regs_start_at_lut = start_at_lut_lut[inst]
        for _, reg in ipairs(list) do
          live_regs[#live_regs+1] = reg
        end
      end
      live_regs = util.shallow_copy(live_regs)
      -- stopping at this instruction, remove them from live_regs for the next instruction
      local lut = stop_at_lut_lut[inst]
      if lut then
        inst.regs_stop_at_list = stop_at_list_lut[inst]
        inst.regs_stop_at_lut = lut
        local i = 1
        local j = 1
        local c = #live_regs
        while i <= c do
          local reg = live_regs[i]
          live_regs[i] = nil
          if not lut[reg] then -- if it's not stopping it's still alive
            live_regs[j] = reg
            j = j + 1
          end
          i = i + 1
        end
      end
      inst = inst.next
    end

    data.func.has_reg_liveliness = true
  end
end

---@param reg ILRegister
local function determine_temporary(reg)
  reg.temporary = reg.total_get_count <= 1 and reg.total_set_count <= 1
  if reg.is_vararg and not reg.temporary then
    util.debug_abort("Malformed vararg register. Vararg registers must only be set once and used once.")
  end
end

local add_reg_usage_for_reg_for_inst
local determine_reg_usage_for_inst
local determine_reg_usage
do
  ---@param reg ILRegister
  function add_reg_usage_for_reg_for_inst(data, inst, reg, get_set)
    reg.total_get_count = reg.total_get_count or 0
    reg.total_set_count = reg.total_set_count or 0
    if get_set ~= set_flag then
      reg.total_get_count = reg.total_get_count + 1
    end
    if get_set ~= get_flag then
      reg.total_set_count = reg.total_set_count + 1
    end
    determine_temporary(reg)
  end

  function determine_reg_usage_for_inst(inst)
    visit_regs_for_inst(nil, inst, add_reg_usage_for_reg_for_inst)
  end

  ---@param func ILFunction
  function determine_reg_usage(func)
    local inst = func.instructions.first
    while inst do
      visit_regs_for_inst(nil, inst, add_reg_usage_for_reg_for_inst)
      inst = inst.next
    end
    func.has_reg_usage = true
  end
end

local remove_reg_usage_for_reg_for_inst
do
  ---@param reg ILRegister
  function remove_reg_usage_for_reg_for_inst(data, inst, reg, get_set)
    if get_set ~= set_flag then
      reg.total_get_count = reg.total_get_count - 1
    end
    if get_set ~= get_flag then
      reg.total_set_count = reg.total_set_count - 1
    end
    determine_temporary(reg)
  end
end

----------------------------------------------------------------------------------------------------
-- il modifications
----------------------------------------------------------------------------------------------------

-- when inserting instructions ensure that the following is updated:
-- - [x] func.instructions
-- - [x] func.blocks
-- - [ ] think about inserting closures
-- - [x] inst.block
-- - [x] inst.regs_start_at_list
-- - [x] inst.regs_start_at_lut
-- - [x] inst.regs_stop_at_list
-- - [x] inst.regs_stop_at_lut
-- - [x] inst.live_regs
-- - [ ] inst.pre_state
-- - [ ] inst.post_state
-- - [x] reg.start_at
-- - [x] reg.stop_at
-- - [x] reg.total_get_count
-- - [x] reg.total_set_count
-- - [x] reg.temporary
--
-- - [ ] reg.captured_as_upval
-- - [ ] reg.current_reg

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param get_set 1|2|3
local function add_reg_to_inst(func, inst, reg, get_set, allow_modifying_inst_group)
  if inst.inst_group and not allow_modifying_inst_group then
    util.debug_abort("Attempt to add a register to an inst in inst_group (which are immutable).")
  end
  if func.has_start_stop_insts then
    -- `func.has_reg_liveliness` is checked for in the following function
    add_start_stop_and_liveliness_for_reg_for_inst(func, inst, reg)
  end
  if func.has_reg_usage then
    add_reg_usage_for_reg_for_inst(nil, inst, reg, get_set)
  end
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param allow_modifying_inst_group boolean? @ only ever set this to true if you're certain it's correct
local function add_reg_to_inst_get(func, inst, reg, allow_modifying_inst_group)
  add_reg_to_inst(func, inst, reg, 1, allow_modifying_inst_group)
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param allow_modifying_inst_group boolean? @ only ever set this to true if you're certain it's correct
local function add_reg_to_inst_set(func, inst, reg, allow_modifying_inst_group)
  add_reg_to_inst(func, inst, reg, 2, allow_modifying_inst_group)
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param get_set 1|2|3
---@param allow_modifying_inst_group boolean?
local function remove_reg_from_inst(func, inst, reg, get_set, allow_modifying_inst_group)
  if inst.inst_group and not allow_modifying_inst_group then
    util.debug_abort("Attempt to remove a register from an inst in inst_group (which are immutable).")
  end
  if func.has_start_stop_insts then
    -- `func.has_reg_liveliness` is checked for in the following function
    remove_start_stop_and_liveliness_for_reg_for_inst(func, inst, reg)
  end
  if func.has_reg_usage then
    remove_reg_usage_for_reg_for_inst(nil, inst, reg, get_set)
  end
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param allow_modifying_inst_group boolean? @ only ever set this to true if you're certain it's correct
local function remove_reg_from_inst_get(func, inst, reg, allow_modifying_inst_group)
  remove_reg_from_inst(func, inst, reg, 1, allow_modifying_inst_group)
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param allow_modifying_inst_group boolean? @ only ever set this to true if you're certain it's correct
local function remove_reg_from_inst_set(func, inst, reg, allow_modifying_inst_group)
  remove_reg_from_inst(func, inst, reg, 2, allow_modifying_inst_group)
end

---@param func ILFunction
---@param inst ILInstruction
local function update_intermediate_data(func, inst)
  if func.has_start_stop_insts then
    -- `func.has_reg_liveliness` is checked for in the following function
    eval_start_stop_and_liveliness_for_regs_for_inst(func, inst)
  end
  if func.has_reg_usage then
    determine_reg_usage_for_inst(inst)
  end
end

---@param func ILFunction
---@param inst ILInstruction?
---@param inserted_inst ILInstruction
---@return ILInstruction
local function insert_after_inst(func, inst, inserted_inst)
  if inst and inst.inst_group and inst ~= inst.inst_group.stop then
    util.debug_abort("Attempt to insert an instruction inside of an inst_group (which are immutable).")
  end
  ill.insert_after(func.instructions, inst, inserted_inst)
  update_intermediate_data(func, inserted_inst)
  if func.has_blocks then
    normalize_blocks_for_inst(func, inserted_inst)
  end
  return inserted_inst
end

---@param func ILFunction
---@param inst ILInstruction?
---@param inserted_inst ILInstruction
---@return ILInstruction
local function insert_before_inst(func, inst, inserted_inst)
  if inst and inst.inst_group and inst ~= inst.inst_group.start then
    util.debug_abort("Attempt to insert an instruction inside of an inst_group (which are immutable).")
  end
  ill.insert_before(func.instructions, inst, inserted_inst)
  update_intermediate_data(func, inserted_inst)
  if func.has_blocks then
    normalize_blocks_for_inst(func, inserted_inst)
  end
  return inserted_inst
end

---@param func ILFunction
---@param inserted_inst ILInstruction
---@return ILInstruction
local function prepend_inst(func, inserted_inst)
  ill.prepend(func.instructions, inserted_inst)
  update_intermediate_data(func, inserted_inst)
  if func.has_blocks then
    normalize_blocks_for_inst(func, inserted_inst)
  end
  return inserted_inst
end

---@param func ILFunction
---@param inserted_inst ILInstruction
---@return ILInstruction
local function append_inst(func, inserted_inst)
  ill.append(func.instructions, inserted_inst)
  update_intermediate_data(func, inserted_inst)
  if func.has_blocks then
    normalize_blocks_for_inst(func, inserted_inst)
  end
  return inserted_inst
end

---@param func ILFunction
---@param forprep_group ILForprepGroup
---@param new_index_reg ILRegister
local function replace_forprep_index_reg(func, forprep_group, new_index_reg)
  local old_reg = forprep_group.index_reg
  forprep_group.index_reg = new_index_reg

  local iter = ill.iterate(func.instructions, forprep_group.start)
  do -- to_number for index_reg
    local inst = iter()--[[@as ILToNumber]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.right_ptr = new_index_reg
    add_reg_to_inst_get(func, inst, new_index_reg, true)
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_index_reg
    add_reg_to_inst_set(func, inst, new_index_reg, true)
  end
  iter() -- skip to_number for limit_reg
  iter() -- skip to_number for step_reg
  do -- binop to subtract step from index
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_index_reg
    add_reg_to_inst_get(func, inst, new_index_reg, true)
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_index_reg
    add_reg_to_inst_set(func, inst, new_index_reg, true)
  end
end

---@param func ILFunction
---@param forprep_group ILForprepGroup
---@param new_limit_reg ILRegister
local function replace_forprep_limit_reg(func, forprep_group, new_limit_reg)
  local old_reg = forprep_group.limit_reg
  forprep_group.limit_reg = new_limit_reg

  local iter = ill.iterate(func.instructions, forprep_group.start)
  iter() -- skip to_number for index_reg
  do -- to_number for limit_reg
    local inst = iter()--[[@as ILToNumber]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.right_ptr = new_limit_reg
    add_reg_to_inst_get(func, inst, new_limit_reg, true)
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_limit_reg
    add_reg_to_inst_set(func, inst, new_limit_reg, true)
  end
end

---@param func ILFunction
---@param forprep_group ILForprepGroup
---@param new_step_reg ILRegister
local function replace_forprep_step_reg(func, forprep_group, new_step_reg)
  local old_reg = forprep_group.step_reg
  forprep_group.step_reg = new_step_reg

  local iter = ill.iterate(func.instructions, forprep_group.start)
  iter() -- skip to_number for index_reg
  iter() -- skip to_number for limit_reg
  do -- to_number for step_reg
    local inst = iter()--[[@as ILToNumber]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.right_ptr = new_step_reg
    add_reg_to_inst_get(func, inst, new_step_reg, true)
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_step_reg
    add_reg_to_inst_set(func, inst, new_step_reg, true)
  end
  do -- binop to subtract step from index
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.right_ptr = new_step_reg
    add_reg_to_inst_get(func, inst, new_step_reg, true)
  end
end

---@param func ILFunction
---@param forloop_group ILForloopGroup
---@param new_index_reg ILRegister
local function replace_forloop_index_reg(func, forloop_group, new_index_reg)
  local old_reg = forloop_group.index_reg
  forloop_group.index_reg = new_index_reg

  local iter = ill.iterate(func.instructions, forloop_group.start)
  do -- binop incrementing index_reg (saved to temp reg)
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_index_reg
    add_reg_to_inst_get(func, inst, new_index_reg, true)
  end
  iter() -- skip binop for test `step > 0`
  iter() -- skip test for test `step > 0`
  -- in the branch: `if step <= 0 then`
  iter() -- skip binop for `if index < limit then break end`
  iter() -- skip test for `if index < limit then break end`
  iter() -- skip jump for `if index < limit then break end`

  iter() -- skip label - jump target for second branch
  -- in the branch: `if step > 0 then`
  iter() -- skip binop for `if index > limit then break end`
  iter() -- skip test for `if index > limit then break end`

  iter() -- skip label - jump target for first branch (on success)
  do -- move `index = incremented_index`
    local inst = iter()--[[@as ILMove]]
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_index_reg
    add_reg_to_inst_set(func, inst, new_index_reg, true)
  end
  -- commented out because they're not needed, but kept for the comments
  -- iter() -- skip move `local_var = incremented_index`
  -- iter() -- skip jump back up, next loop iteration (the target label isn't apart of the group)

  -- iter() -- skip label - jump target for leave and break jumps
end

---@param func ILFunction
---@param forloop_group ILForloopGroup
---@param new_limit_reg ILRegister
local function replace_forloop_limit_reg(func, forloop_group, new_limit_reg)
  local old_reg = forloop_group.limit_reg
  forloop_group.limit_reg = new_limit_reg

  local iter = ill.iterate(func.instructions, forloop_group.start)
  iter() -- skip binop incrementing index_reg (saved to temp reg)
  iter() -- skip binop for test `step > 0`
  iter() -- skip test for test `step > 0`
  -- in the branch: `if step <= 0 then`
  do -- binop for `if index < limit then break end`
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_limit_reg
    add_reg_to_inst_get(func, inst, new_limit_reg, true)
  end
  iter() -- skip test for `if index < limit then break end`
  iter() -- skip jump for `if index < limit then break end`

  iter() -- skip label - jump target for second branch
  -- in the branch: `if step > 0 then`
  do -- binop for `if index > limit then break end`
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_limit_reg
    add_reg_to_inst_get(func, inst, new_limit_reg, true)
  end
  -- commented out because they're not needed, but kept for the comments
  -- iter() -- skip test for `if index > limit then break end`

  -- iter() -- skip label - jump target for first branch (on success)
  -- iter() -- skip move `index = incremented_index`
  -- iter() -- skip move `local_var = incremented_index`
  -- iter() -- skip jump back up, next loop iteration (the target label isn't apart of the group)

  -- iter() -- skip label - jump target for leave and break jumps
end

---@param func ILFunction
---@param forloop_group ILForloopGroup
---@param new_step_reg ILRegister
local function replace_forloop_step_reg(func, forloop_group, new_step_reg)
  local old_reg = forloop_group.step_reg
  forloop_group.step_reg = new_step_reg

  local iter = ill.iterate(func.instructions, forloop_group.start)
  do -- incrementing index_reg (saved to temp reg)
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_step_reg
    add_reg_to_inst_get(func, inst, new_step_reg, true)
  end
  do -- binop for test `step > 0`
    local inst = iter()--[[@as ILBinop]]
    remove_reg_from_inst_get(func, inst, old_reg, true)
    inst.left_ptr = new_step_reg
    add_reg_to_inst_get(func, inst, new_step_reg, true)
  end
  -- commented out because they're not needed, but kept for the comments
  -- iter() -- skip test for test `step > 0`
  -- -- in the branch: `if step <= 0 then`
  -- iter() -- skip binop for `if index < limit then break end`
  -- iter() -- skip test for `if index < limit then break end`
  -- iter() -- skip jump for `if index < limit then break end`

  -- iter() -- skip label - jump target for second branch
  -- -- in the branch: `if step > 0 then`
  -- iter() -- skip binop for `if index > limit then break end`
  -- iter() -- skip test for `if index > limit then break end`

  -- iter() -- skip label - jump target for first branch (on success)
  -- iter() -- skip move `index = incremented_index`
  -- iter() -- skip move `local_var = incremented_index`
  -- iter() -- skip jump back up, next loop iteration (the target label isn't apart of the group)

  -- iter() -- skip label - jump target for leave and break jumps
end

---@param func ILFunction
---@param forloop_group ILForloopGroup
---@param new_local_reg ILRegister
local function replace_forloop_local_reg(func, forloop_group, new_local_reg)
  local old_reg = forloop_group.local_reg
  forloop_group.local_reg = new_local_reg

  local iter = ill.iterate(func.instructions, forloop_group.start)
  iter() -- skip incrementing index_reg (saved to temp reg)
  iter() -- skip binop for test `step > 0`
  iter() -- skip test for test `step > 0`
  -- in the branch: `if step <= 0 then`
  iter() -- skip binop for `if index < limit then break end`
  iter() -- skip test for `if index < limit then break end`
  iter() -- skip jump for `if index < limit then break end`

  iter() -- skip label - jump target for second branch
  -- in the branch: `if step > 0 then`
  iter() -- skip binop for `if index > limit then break end`
  iter() -- skip test for `if index > limit then break end`

  iter() -- skip label - jump target for first branch (on success)
  iter() -- skip move `index = incremented_index`
  do -- move `local_var = incremented_index`
    local inst = iter()--[[@as ILMove]]
    remove_reg_from_inst_set(func, inst, old_reg, true)
    inst.result_reg = new_local_reg
    add_reg_to_inst_set(func, inst, new_local_reg, true)
  end
  -- commented out because they're not needed, but kept for the comments
  -- iter() -- skip jump back up, next loop iteration (the target label isn't apart of the group)

  -- iter() -- skip label - jump target for leave and break jumps
end

return {

  -- instructions

  new_forprep_group = new_forprep_group,
  new_forloop_group = new_forloop_group,
  new_tforcall_group = new_tforcall_group,
  new_tforloop_group = new_tforloop_group,

  new_move = new_move,
  new_get_upval = new_get_upval,
  new_set_upval = new_set_upval,
  new_get_table = new_get_table,
  new_set_table = new_set_table,
  new_set_list = new_set_list,
  new_new_table = new_new_table,
  new_concat = new_concat,
  new_binop = new_binop,
  new_unop = new_unop,
  new_label = new_label,
  new_jump = new_jump,
  new_test = new_test,
  new_call = new_call,
  new_ret = new_ret,
  new_closure = new_closure,
  new_vararg = new_vararg,
  new_close_up = new_close_up,
  new_scoping = new_scoping,
  new_to_number = new_to_number,

  -- pointers

  new_reg = new_reg,
  gap_reg = gap_reg,
  new_vararg_reg = new_vararg_reg,
  new_number = new_number,
  new_string = new_string,
  new_boolean = new_boolean,
  new_nil = new_nil,

  -- instruction helpers

  is_inst_group = is_inst_group,
  get_inst_or_group = get_inst_or_group,
  get_prev_inst_or_group = get_prev_inst_or_group,
  get_next_inst_or_group = get_next_inst_or_group,
  iterate_insts_and_groups = iterate_insts_and_groups,
  iterate_insts_in_group = iterate_insts_in_group,
  get_live_regs = get_live_regs,
  get_regs_stop_at_list = get_regs_stop_at_list,
  get_regs_stop_at_lut = get_regs_stop_at_lut,
  get_regs_start_at_list = get_regs_start_at_list,
  get_regs_start_at_lut = get_regs_start_at_lut,

  -- types

  nil_flag = nil_flag,
  boolean_flag = boolean_flag,
  number_flag = number_flag,
  string_flag = string_flag,
  function_flag = function_flag,
  table_flag = table_flag,
  userdata_flag = userdata_flag,
  thread_flag = thread_flag,
  every_flag = every_flag,
  new_type = new_type,
  copy_identity = copy_identity,
  copy_identities = copy_identities,
  copy_class = copy_class,
  copy_classes = copy_classes,
  copy_type = copy_type,
  copy_types = copy_types,
  equals = equals,
  union = union,
  intersect = intersect,
  contains = contains,
  exclude = exclude,
  has_all_flags = has_all_flags,
  has_any_flags = has_any_flags,
  class_indexing = class_indexing,
  type_indexing = type_indexing,
  class_new_indexing = class_new_indexing,
  type_new_indexing = type_new_indexing,

  -- il blocks

  new_block = new_block,
  create_links_for_block = create_links_for_block,
  normalize_blocks_for_inst = normalize_blocks_for_inst,

  -- il registers

  is_vararg_list = is_vararg_list,
  get_flag = get_flag,
  set_flag = set_flag,
  get_and_set_flags = get_and_set_flags,
  visit_regs_for_inst = visit_regs_for_inst,
  visit_all_regs = visit_all_regs,
  eval_start_stop_for_all_regs = eval_start_stop_for_all_regs,
  eval_start_stop_and_liveliness_for_regs_for_inst = eval_start_stop_and_liveliness_for_regs_for_inst,
  eval_live_regs = eval_live_regs,
  determine_reg_usage_for_inst = determine_reg_usage_for_inst,
  determine_reg_usage = determine_reg_usage,

  -- il modifications

  add_reg_to_inst_get = add_reg_to_inst_get,
  add_reg_to_inst_set = add_reg_to_inst_set,
  remove_reg_from_inst_get = remove_reg_from_inst_get,
  remove_reg_from_inst_set = remove_reg_from_inst_set,
  update_intermediate_data = update_intermediate_data,
  insert_after_inst = insert_after_inst,
  insert_before_inst = insert_before_inst,
  prepend_inst = prepend_inst,
  append_inst = append_inst,

  replace_forprep_index_reg = replace_forprep_index_reg,
  replace_forprep_limit_reg = replace_forprep_limit_reg,
  replace_forprep_step_reg = replace_forprep_step_reg,
  replace_forloop_index_reg = replace_forloop_index_reg,
  replace_forloop_limit_reg = replace_forloop_limit_reg,
  replace_forloop_step_reg = replace_forloop_step_reg,
  replace_forloop_local_reg = replace_forloop_local_reg,
}
