
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local ill = require("indexed_linked_list")
local ll = require("linked_list")
local il = require("il_util")
local linq = require("linq")

-- FIXME: 'live_regs' have been moved from instructions to borders. This file is not updated.

local generate
do
  ---@param data ILCompilerData
  ---@param position Position
  ---@param op Opcode
  ---@param args InstructionArguments
  ---@return ILCompiledInstruction
  local function new_inst(data, position, op, args)
    args.line = position and position.line
    args.column = position and position.column
    args.op = op
    return args--[[@as ILCompiledInstruction]]
  end

  ---@param data ILCompilerData
  ---@param inst ILCompiledInstruction
  local function add_inst(data, inst)
    ll.prepend(data.compiled_instructions, inst)
  end

  ---@param data ILCompilerData
  ---@param position Position
  ---@param op Opcode
  ---@param args InstructionArguments
  ---@return ILCompiledInstruction inst
  local function add_new_inst(data, position, op, args)
    local inst = new_inst(data, position, op, args)
    add_inst(data, inst)
    return inst
  end

  ---@param data ILCompilerData
  ---@return ILCompiledInstruction
  local function get_first_inst(data)
    return data.compiled_instructions.first--[[@as ILCompiledInstruction]]
  end

  ---@class ILCompiledRegister
  ---@field reg_index integer @ **zero based**
  ---@field name string?
  ---@field start_at ILCompiledInstruction @ inclusive
  ---@field stop_at ILCompiledInstruction? @ exclusive. When `nil` stops at the very end

  ---@class ILCompiledInstruction : Instruction
  ---@field inst_index integer
  ---@field prev ILCompiledInstruction?
  ---@field next ILCompiledInstruction?

  local live_regs = {} -- DEBUG: to know which regs are alive while an error occurs

  ---@param data ILCompilerData
  ---@param il_reg ILRegister? @ -- DEBUG
  ---@return ILCompiledRegister
  local function create_compiled_reg(data, reg_index, name, il_reg)
    if reg_index >= data.result.max_stack_size then
      data.result.max_stack_size = reg_index + 1
    end
    if reg_index < data.local_reg_count then
      util.debug_assert(
        data.local_reg_gaps[reg_index],
        "Attempt to create a register with the index "..reg_index.." while that index is occupied."
      )
      data.local_reg_gaps[reg_index] = nil
    else
      for i = data.local_reg_count, reg_index - 1 do
        data.local_reg_gaps[i] = true
      end
      data.local_reg_count = reg_index + 1
    end
    local reg = {
      reg_index = reg_index,
      name = name,
      start_at = nil,
      stop_at = get_first_inst(data),
      il_reg = il_reg, -- DEBUG
    }
    live_regs[reg_index] = reg
    return reg
  end

  ---@param data ILCompilerData
  local function create_new_reg_at_top(data, name)
    return create_compiled_reg(data, data.local_reg_count, name)
  end

  ---@param data ILCompilerData
  ---@param reg ILCompiledRegister
  local function stop_reg(data, reg)
    if reg.reg_index ~= data.local_reg_count - 1 then
      data.local_reg_gaps[reg.reg_index] = true
      -- it might maybe sometimes make sense to actually shift registers into the gap, but it's probably just
      -- a wasted move instruction. Plus shifting registers captured as upvalues is forbidden
    else
      local stopped_reg_count = 1
      while data.local_reg_gaps[data.local_reg_count - stopped_reg_count - 1] do
        data.local_reg_gaps[data.local_reg_count - stopped_reg_count - 1] = nil
        stopped_reg_count = stopped_reg_count + 1
      end
      data.local_reg_count = data.local_reg_count - stopped_reg_count
    end
    reg.start_at = get_first_inst(data)
    data.compiled_registers_count = data.compiled_registers_count + 1
    data.compiled_registers[data.compiled_registers_count] = reg
    live_regs[reg.reg_index] = nil
  end

  local generate_inst_lut
  local generate_inst_group_lut
  local generate_inst
  local generate_inst_group
  do
    local regs = {} ---@type ILRegister[]

    local function fill_regs_using_regs_list(list)
      for _, reg in ipairs(list) do
        regs[#regs+1] = reg
      end
    end

    local function sort_regs()
      table.sort(regs, function(left, right)
        return left.predetermined_reg_index < right.predetermined_reg_index
      end)
    end

    -- when reading these functions remember that we are generating from back to front

    ---@param data ILCompilerData
    ---@param reg_list ILRegister[]
    local function stop_regs_for_list(data, reg_list)
      fill_regs_using_regs_list(reg_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      table.sort(regs, function(left, right)
        return left.predetermined_reg_index > right.predetermined_reg_index
      end)
      for i = reg_count, 1, -1 do
        if regs[i].current_reg then
          stop_reg(data, regs[i].current_reg)
        else
          util.debug_assert(
            il.get_inst_or_group(regs[i].start_at) == il.get_inst_or_group(regs[i].stop_at),
            "Only in the case of registers which start and stop at the same instruction can current_reg \z
              be nil when trying to stop them.\z
            "
          )
          regs[i].instantly_stop_again = true
        end
        regs[i] = nil
      end
    end

    local function stop_regs_for_inst(data, inst)
      if not inst.regs_start_at_list then return end
      stop_regs_for_list(data, inst.regs_start_at_list)
    end

    ---@param data ILCompilerData
    ---@param position Position
    ---@param reg_list ILRegister[]
    local function start_regs_for_list(data, position, reg_list)
      fill_regs_using_regs_list(reg_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      sort_regs()
      local reg_index_to_close_upvals_from
      for i = 1, reg_count do
        local reg = regs[i]
        regs[i] = nil
        reg.current_reg = create_compiled_reg(data, reg.predetermined_reg_index, reg.name, reg)
        if reg.captured_as_upval and not reg_index_to_close_upvals_from then
          reg_index_to_close_upvals_from = reg.current_reg.reg_index
        end
        if reg.instantly_stop_again then
          stop_reg(data, reg.current_reg)
        end
      end
      -- do this after all regs have been created - all regs are alive - for nice and clean debug symbols
      if reg_index_to_close_upvals_from then
        add_new_inst(data, position, opcodes.jmp, {
          a = reg_index_to_close_upvals_from + 1,
          sbx = 0,
        })
      end
    end

    ---@param data ILCompilerData
    ---@param inst ILInstruction
    local function start_regs_for_inst(data, inst)
      if not inst.regs_stop_at_list then return end
      start_regs_for_list(data, inst.position, inst.regs_stop_at_list)
    end

    ---@param data ILCompilerData
    ---@param inst_group ILInstructionGroup
    function generate_inst_group(data, inst_group)
      local start_at_list = il.get_regs_start_at_list(inst_group)
      local stop_at_list = il.get_regs_stop_at_list(inst_group)
      stop_regs_for_list(data, start_at_list)
      start_regs_for_list(data, inst_group.start.position, stop_at_list)
      return generate_inst_group_lut[inst_group.group_type](data, inst_group)
    end

    ---@param inst ILInstruction
    function generate_inst(data, inst)
      stop_regs_for_inst(data, inst)
      start_regs_for_inst(data, inst)
      return generate_inst_lut[inst.inst_type](data, inst)
    end
  end

  ---@param data ILCompilerData
  ---@param reg ILCompiledRegister
  local function ensure_reg_is_at_top(data, reg)
    if reg.reg_index < data.local_reg_count - 1 then
      util.debug_abort("The pre process steps didn't ensure that the result reg for new_table and concat are at top.")
    end
  end

  ---@param data ILCompilerData
  local function add_constant(data, ptr)
    -- NOTE: what does this mean: [...]
    -- unless const table is too big, then fetch into temporary (and emit warning: const table too large)
    -- (comment was from justarandomgeek originally in the binop function)

    if ptr.ptr_type == "nil" then
      if data.nil_constant_idx then
        return data.nil_constant_idx
      end
      data.nil_constant_idx = data.constants_count
      data.constants_count = data.constants_count + 1
      data.result.constants[data.nil_constant_idx+1] = {node_type = "nil"}
      return data.nil_constant_idx
    end

    if ptr.value ~= ptr.value then
      if data.nan_constant_idx then
        return data.nan_constant_idx
      end
      data.nan_constant_idx = data.constants_count
      data.constants_count = data.constants_count + 1
      data.result.constants[data.nan_constant_idx+1] = {node_type = "number", value = 0/0}
      return data.nan_constant_idx
    end

    if data.constant_lut[ptr.value] then
      return data.constant_lut[ptr.value]
    end
    local i = data.constants_count
    data.constants_count = data.constants_count + 1
    data.result.constants[i+1] = {
      node_type = ptr.ptr_type,
      value = ptr.value,
    }
    data.constant_lut[ptr.value] = i
    return i
  end

  ---@param data ILCompilerData
  ---@param position Position
  ---@param ptr ILPointer
  ---@param result_reg ILCompiledRegister
  local function add_load_constant(data, position, ptr, result_reg)
    if ptr.ptr_type == "nil" then
      add_new_inst(data, position, opcodes.loadnil, {
        a = result_reg.reg_index,
        b = 0,
      })
    elseif ptr.ptr_type == "boolean" then
      add_new_inst(data, position, opcodes.loadbool, {
        a = result_reg.reg_index,
        b = (ptr--[[@as ILBoolean]]).value and 1 or 0,
        c = 0,
      })
    else -- "number" and "string"
      local k = add_constant(data, ptr)
      if k <= 0x3ffff then
        add_new_inst(data, position, opcodes.loadk, {
          a = result_reg.reg_index,
          bx = k,
        })
      else
        add_new_inst(data, position, opcodes.loadkx, {
          a = result_reg.reg_index,
        })
        add_new_inst(data, position, opcodes.extraarg, {
          ax = k,
        })
      end
    end
  end

  ---@param data ILCompilerData
  ---@param position Position
  ---@param ptr ILPointer
  ---@return integer|ILCompiledRegister const_or_result_reg
  local function const_or_ref_or_load_ptr_pre(data, position, ptr)
    if ptr.ptr_type == "reg" then
      return util.debug_assert((ptr--[[@as ILRegister]]).current_reg,
        "A register must have an index when referring to it."
      )
    else
      local k = add_constant(data, ptr)
      if k <= 0xff then
        return k
      end
      return create_new_reg_at_top(data)
    end
  end

  ---@param const_or_result_reg integer|ILCompiledRegister
  local function get_const_or_reg_arg(const_or_result_reg)
    if type(const_or_result_reg) == "number" then
      return 0x100 + const_or_result_reg
    else
      return const_or_result_reg.reg_index
    end
  end

  ---@param data ILCompilerData
  ---@param position Position
  ---@param ptr ILPointer
  ---@param const_or_result_reg integer|ILCompiledRegister
  local function const_or_ref_or_load_ptr_post(data, position, ptr, const_or_result_reg)
    if ptr.ptr_type == "reg" or type(const_or_result_reg) == "number" then
      -- do nothing
    else
      ---@cast const_or_result_reg ILCompiledRegister
      add_load_constant(data, position, ptr, const_or_result_reg)
      stop_reg(data, const_or_result_reg)
    end
  end

  ---@param data ILCompilerData
  ---@param ptr ILPointer
  ---@return ILCompiledRegister result_reg
  local function ref_or_load_ptr_pre(data, ptr)
    if ptr.ptr_type == "reg" then
      return (ptr--[[@as ILRegister]]).current_reg
    else
      return create_new_reg_at_top(data)
    end
  end

  ---@param data ILCompilerData
  ---@param position Position
  ---@param ptr ILPointer
  ---@param result_reg ILCompiledRegister
  local function ref_or_load_ptr_post(data, position, ptr, result_reg)
    if ptr.ptr_type == "reg" then
      -- do nothing
    else
      add_load_constant(data, position, ptr, result_reg)
      stop_reg(data, result_reg)
    end
  end

  local bin_opcode_lut = {
    ["+"] = opcodes.add,
    ["-"] = opcodes.sub,
    ["*"] = opcodes.mul,
    ["/"] = opcodes.div,
    ["%"] = opcodes.mod,
    ["^"] = opcodes.pow,
  }
  local logical_binop_lut = {
    ["=="] = opcodes.eq,
    ["<"] = opcodes.lt,
    ["<="] = opcodes.le,
    ["~="] = opcodes.eq, -- inverted
    [">="] = opcodes.lt, -- inverted
    [">"] = opcodes.le, -- inverted
  }
  local logical_invert_lut = {
    ["=="] = false,
    ["<"] = false,
    ["<="] = false,
    ["~="] = true,
    [">="] = true,
    [">"] = true,
  }
  local un_opcodes = {
    ["-"] = opcodes.unm,
    ["#"] = opcodes.len,
    ["not"] = opcodes["not"],
  }

  ---@param inst ILJump|ILTest
  local function get_a_for_jump(inst)
    local regs_still_alive_lut = {}
    for _, reg in ipairs(inst.label.live_regs) do
      regs_still_alive_lut[reg] = true
    end
    -- live_regs are not guaranteed to be in any order, so loop through all of them
    local result
    for _, reg in ipairs(inst.live_regs) do
      if reg.captured_as_upval and not regs_still_alive_lut[reg]
        and (not result or reg.current_reg.reg_index < result)
      then
        result = reg.current_reg.reg_index + 1
      end
    end
    return result or 0
  end

  ---@type table<ILInstructionType, fun(data: ILCompilerData, inst: ILInstruction): ILInstruction>
  generate_inst_lut = {
    ---@param inst ILMove
    ["move"] = function(data, inst)
      if inst.right_ptr.ptr_type == "reg" then
        local a = inst.result_reg.current_reg.reg_index
        local b = (inst.right_ptr--[[@as ILRegister]]).current_reg.reg_index
        if a ~= b then
          add_new_inst(data, inst.position, opcodes.move, {
            a = a,
            b = b,
          })
        end
      else
        add_load_constant(data, inst.position, inst.right_ptr, inst.result_reg.current_reg)
      end
      return inst.prev
    end,
    ---@param inst ILGetUpval
    ["get_upval"] = function(data, inst)
      add_new_inst(data, inst.position, opcodes.getupval, {
        a = inst.result_reg.current_reg.reg_index,
        b = inst.upval.upval_index,
      })
      return inst.prev
    end,
    ---@param inst ILSetUpval
    ["set_upval"] = function(data, inst)
      local right_reg = ref_or_load_ptr_pre(data, inst.right_ptr)
      add_new_inst(data, inst.position, opcodes.setupval, {
        a = right_reg.reg_index,
        b = inst.upval.upval_index,
      })
      ref_or_load_ptr_post(data, inst.position, inst.right_ptr, right_reg)
      return inst.prev
    end,
    ---@param inst ILGetTable
    ["get_table"] = function(data, inst)
      local key = const_or_ref_or_load_ptr_pre(data, inst.position, inst.key_ptr)
      add_new_inst(data, inst.position, opcodes.gettable, {
        a = inst.result_reg.current_reg.reg_index,
        b = inst.table_reg.current_reg.reg_index,
        c = get_const_or_reg_arg(key),
      })
      const_or_ref_or_load_ptr_post(data, inst.position, inst.key_ptr, key)
      return inst.prev
    end,
    ---@param inst ILSetTable
    ["set_table"] = function(data, inst)
      local key = const_or_ref_or_load_ptr_pre(data, inst.position, inst.key_ptr)
      local right = const_or_ref_or_load_ptr_pre(data, inst.position, inst.right_ptr)
      add_new_inst(data, inst.position, opcodes.settable, {
        a = inst.table_reg.current_reg.reg_index,
        b = get_const_or_reg_arg(key),
        c = get_const_or_reg_arg(right),
      })
      const_or_ref_or_load_ptr_post(data, inst.position, inst.right_ptr, right)
      const_or_ref_or_load_ptr_post(data, inst.position, inst.key_ptr, key)
      return inst.prev
    end,
    ---@param inst ILSetList
    ["set_list"] = function(data, inst)
      local is_vararg = (inst.right_ptrs[#inst.right_ptrs]--[[@as ILRegister]]).is_vararg
      add_new_inst(data, inst.position, opcodes.setlist, {
        a = inst.table_reg.current_reg.reg_index,
        b = is_vararg and 0 or #inst.right_ptrs,
        c = ((inst.start_index - 1) / phobos_consts.fields_per_flush) + 1,
      })
      return inst.prev
    end,
    ---@param inst ILNewTable
    ["new_table"] = function(data, inst)
      ensure_reg_is_at_top(data, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.newtable, {
        a = inst.result_reg.current_reg.reg_index,
        b = util.number_to_floating_byte(inst.array_size),
        c = util.number_to_floating_byte(inst.hash_size),
      })
      return inst.prev
    end,
    ---@param inst ILConcat
    ["concat"] = function(data, inst)
      local register_list_index = (inst.right_ptrs[1]--[[@as ILRegister]]).current_reg.reg_index
      add_new_inst(data, inst.position, opcodes.concat, {
        a = inst.result_reg.current_reg.reg_index,
        b = register_list_index,
        c = register_list_index + #inst.right_ptrs - 1,
      })
      return inst.prev
    end,
    ---@param inst ILBinop
    ["binop"] = function(data, inst)
      if bin_opcode_lut[inst.op] then
        -- order matters, back to front
        local right = const_or_ref_or_load_ptr_pre(data, inst.position, inst.right_ptr)
        local left = const_or_ref_or_load_ptr_pre(data, inst.position, inst.left_ptr)
        add_new_inst(data, inst.position, bin_opcode_lut[inst.op], {
          a = inst.result_reg.current_reg.reg_index,
          b = get_const_or_reg_arg(left),
          c = get_const_or_reg_arg(right),
        })
        -- order matters, top down
        const_or_ref_or_load_ptr_post(data, inst.position, inst.left_ptr, left)
        const_or_ref_or_load_ptr_post(data, inst.position, inst.right_ptr, right)
      else
        -- remember, generated from back to front
        add_new_inst(data, inst.position, opcodes.loadbool, {
          a = inst.result_reg.current_reg.reg_index,
          b = 0,
          c = 0,
        })
        add_new_inst(data, inst.position, opcodes.loadbool, {
          a = inst.result_reg.current_reg.reg_index,
          b = 1,
          c = 1,
        })
        add_new_inst(data, inst.position, opcodes.jmp, {
          a = 0,
          sbx = 1,
        })
        -- order matters, back to front
        local right = const_or_ref_or_load_ptr_pre(data, inst.position, inst.right_ptr)
        local left = const_or_ref_or_load_ptr_pre(data, inst.position, inst.left_ptr)
        add_new_inst(data, inst.position, logical_binop_lut[inst.op], {
          a = (logical_invert_lut[inst.op] and 1 or 0)--[[@as integer]],
          b = get_const_or_reg_arg(left),
          c = get_const_or_reg_arg(right),
        })
        -- order matters, top down
        const_or_ref_or_load_ptr_post(data, inst.position, inst.left_ptr, left)
        const_or_ref_or_load_ptr_post(data, inst.position, inst.right_ptr, right)
      end
      return inst.prev
    end,
    ---@param inst ILUnop
    ["unop"] = function(data, inst)
      local right_reg = ref_or_load_ptr_pre(data, inst.right_ptr)
      add_new_inst(data, inst.position, un_opcodes[inst.op], {
        a = inst.result_reg.current_reg.reg_index,
        b = right_reg.reg_index,
      })
      ref_or_load_ptr_post(data, inst.position, inst.right_ptr, right_reg)
      return inst.prev
    end,
    ---@param inst ILLabel
    ["label"] = function(data, inst)
      inst.target_inst = get_first_inst(data)
      return inst.prev
    end,
    ---@param inst ILJump
    ["jump"] = function(data, inst)
      inst.jump_inst = add_new_inst(data, inst.position, opcodes.jmp, {
        a = get_a_for_jump(inst),
        -- set after all instructions have been generated - once `inst_index`es have been evaluated
        sbx = (nil)--[[@as integer]],
      })
      data.all_jumps_count = data.all_jumps_count + 1
      data.all_jumps[data.all_jumps_count] = inst
      return inst.prev
    end,
    ---@param data ILCompilerData
    ---@param inst ILTest
    ["test"] = function(data, inst)
      -- remember, generated from back to front, so the jump comes "first"
      inst.jump_inst = add_new_inst(data, inst.position, opcodes.jmp, {
        a = get_a_for_jump(inst),
        -- set after all instructions have been generated - once `inst_index`es have been evaluated
        sbx = (nil)--[[@as integer]],
      })
      data.all_jumps_count = data.all_jumps_count + 1
      data.all_jumps[data.all_jumps_count] = inst
      local condition_reg = ref_or_load_ptr_pre(data, inst.condition_ptr)
      add_new_inst(data, inst.position, opcodes.test, {
        a = condition_reg.reg_index,
        c = inst.jump_if_true and 1 or 0,
      })
      ref_or_load_ptr_post(data, inst.position, inst.condition_ptr, condition_reg)
      return inst.prev
    end,
    ---@param inst ILCall
    ["call"] = function(data, inst)
      local vararg_args = inst.arg_ptrs[1] and (inst.arg_ptrs[#inst.arg_ptrs]--[[@as ILRegister]]).is_vararg
      local vararg_result = inst.result_regs[1] and inst.result_regs[#inst.result_regs].is_vararg
      add_new_inst(data, inst.position, opcodes.call, {
        a = inst.func_reg.current_reg.reg_index,
        b = vararg_args and 0 or (#inst.arg_ptrs + 1),
        c = vararg_result and 0 or (#inst.result_regs + 1),
      })
      return inst.prev
    end,
    ---@param inst ILRet
    ["ret"] = function(data, inst)
      if inst.ptrs[1] then
        local is_vararg = (inst.ptrs[#inst.ptrs]--[[@as ILRegister]]).is_vararg
        add_new_inst(data, inst.position, opcodes["return"], {
          a = (inst.ptrs[1]--[[@as ILRegister]]).current_reg.reg_index,
          b = is_vararg and 0 or (#inst.ptrs + 1),
        })
      else
        add_new_inst(data, inst.position, opcodes["return"], {a = 0, b = 1})
      end
      return inst.prev
    end,
    ---@param inst ILClosure
    ["closure"] = function(data, inst)
      ensure_reg_is_at_top(data, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.closure, {
        a = inst.result_reg.current_reg.reg_index,
        bx = inst.func.closure_index,
      })
      return inst.prev
    end,
    ---@param inst ILVararg
    ["vararg"] = function(data, inst)
      local is_vararg = inst.result_regs[#inst.result_regs].is_vararg
      add_new_inst(data, inst.position, opcodes.vararg, {
        a = inst.result_regs[1].current_reg.reg_index,
        b = is_vararg and 0 or (#inst.result_regs + 1),
      })
      return inst.prev
    end,
    ---@param inst ILCloseUp
    ["close_up"] = function(data, inst)
      -- NOTE: it is currently guaranteed that registers requiring closing do not have any registers above them
      -- because the initial predetermined_reg_index evaluation logic makes sure of that, and that logic
      -- ultimately handles _all_ registers captured as upvalues because said registers are currently never
      -- used in place in register_groups
      local a
      for _, reg in ipairs(inst.regs) do
        if reg.captured_as_upval and (not a or reg.current_reg.reg_index < a) then
          a = reg.current_reg.reg_index + 1
        end
      end
      if a then
        add_new_inst(data, inst.position, opcodes.jmp, {
          a = a,
          sbx = 0,
        })
      end
      return inst.prev
    end,
    ---@param inst ILScoping
    ["scoping"] = function(data, inst)
      -- no op
      return inst.prev
    end,
    ---@param inst ILToNumber
    ["to_number"] = function(data, inst)
      util.abort("Standalone 'to_number' il instructions cannot be compiled. There is no Lua opcode for it. \z
        'to_number' is used inside of forprep instruction groups to represent Lua's implementation of the \z
        forprep opcode."
      ) ---@diagnostic disable-line: missing-return
    end,
  }

  ---@type table<ILInstructionGroupType, fun(data: ILCompilerData, inst_group: ILInstructionGroup): ILInstruction>
  generate_inst_group_lut = {
    ---@param inst_group ILForprepGroup
    ["forprep"] = function(data, inst_group)
      inst_group.loop_jump.jump_inst = add_new_inst(data, inst_group.position, opcodes.forprep, {
        a = inst_group.index_reg.current_reg.reg_index,
        -- set after all instructions have been generated - once `inst_index`es have been evaluated
        sbx = (nil)--[[@as integer]],
      })
      data.all_jumps_count = data.all_jumps_count + 1
      data.all_jumps[data.all_jumps_count] = inst_group.loop_jump
      return inst_group.start.prev
    end,
    ---@param inst_group ILForloopGroup
    ["forloop"] = function(data, inst_group)
      inst_group.loop_jump.jump_inst = add_new_inst(data, inst_group.position, opcodes.forloop, {
        a = inst_group.index_reg.current_reg.reg_index,
        -- set after all instructions have been generated - once `inst_index`es have been evaluated
        sbx = (nil)--[[@as integer]],
      })
      data.all_jumps_count = data.all_jumps_count + 1
      data.all_jumps[data.all_jumps_count] = inst_group.loop_jump
      return inst_group.start.prev
    end,
    ---@param inst_group ILTforcallGroup
    ["tforcall"] = function(data, inst_group)
      util.debug_abort("-- TODO: not implemented")
      return inst_group.start.prev
    end,
    ---@param inst_group ILTforloopGroup
    ["tforloop"] = function(data, inst_group)
      util.debug_abort("-- TODO: not implemented")
      return inst_group.start.prev
    end,
  }

  ---@param data ILCompilerData
  function generate(data)
    local inst = data.func.instructions.last
    while inst do
      if inst.inst_group then
        inst = generate_inst_group(data, inst.inst_group)
      else
        inst = generate_inst(data, inst)
      end
    end
  end
end

---@param func ILFunction
---@return CompiledFunc
local function make_bytecode_func(func)
  local result = {
    line_defined = func.defined_position and func.defined_position.line,
    column_defined = func.defined_position and func.defined_position.column,
    last_line_defined = func.last_defined_position and func.last_defined_position.line,
    last_column_defined = func.last_defined_position and func.last_defined_position.column,
    num_params = #func.param_regs,
    is_vararg = func.is_vararg,
    max_stack_size = 2, -- min 2
    instructions = {},
    constants = {},
    inner_functions = {},
    upvals = {},
    source = func.source,
    debug_registers = {},
  }

  for i, upval in ipairs(func.upvals) do
    upval.upval_index = i - 1 -- **zero based** temporary
    if upval.parent_type == "local" then
      result.upvals[i] = {
        index = 0,
        name = upval.name,
        in_stack = true,
        -- due to order of operations, at this point the registers have been converted to compiled registers
        local_idx = (upval.reg_in_parent_func.current_reg--[[@as CompiledRegister]]).index,
      }
    elseif upval.parent_type == "upval" then
      result.upvals[i] = {
        index = 0,
        name = upval.name,
        in_stack = false,
        upval_idx = upval.parent_upval.upval_index,
      }
    elseif upval.parent_type == "env" then
      result.upvals[i] = {
        index = 0,
        name = "_ENV",
        in_stack = true,
        local_idx = 0,
      }
    end
  end
  for i, inner_func in ipairs(func.inner_functions) do
    inner_func.closure_index = i - 1 -- **zero based**
  end

  return result
end

local pre_compilation_process
do
  ---@param data ILCompilerData
  ---@param left_group ILRegisterGroup
  ---@param right_group ILRegisterGroup
  local function link_register_groups(data, left_group, right_group)
    if left_group.linked_groups then
      if right_group.linked_groups then
        -- already linked
        if left_group.linked_groups == right_group.linked_groups then return end
        -- merge linked groups
        data.all_linked_groups_lut[right_group.linked_groups] = nil
        for other_group in pairs(right_group.linked_groups.groups_lut) do
          left_group.linked_groups.groups_lut[other_group] = true
          other_group.linked_groups = left_group.linked_groups
        end
      else
        -- reuse left linked groups
        right_group.linked_groups = left_group.linked_groups
        right_group.linked_groups.groups_lut[right_group] = true
      end
    else
      if right_group.linked_groups then
        -- reuse right linked groups
        left_group.linked_groups = right_group.linked_groups
        left_group.linked_groups.groups_lut[left_group] = true
      else
        util.debug_abort("Impossible because once a group has been created in group_registers \z
          it must have a linked group"
        )
      end
    end
  end

  ---@param data ILCompilerData
  ---@param left_group ILRegisterGroup
  ---@param right_group ILRegisterGroup
  ---@param offset integer
  local function set_forced_offset_for_groups(data, left_group, right_group, offset)
    link_register_groups(data, left_group, right_group)
    left_group.offset_to_next_group = offset
  end

  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param is_input boolean
  ---@param regs ILRegister[]
  ---@param start_index integer @ start index in `regs`
  local function group_registers(data, inst, is_input, regs, start_index)
    do
      ---@type ILRegister[]
      local new_regs = {}
      local deduplicate_regs_lut = (not is_input and {} or nil)--[[@as table<ILRegister, true>]]
      for i = #regs, start_index, -1 do
        local reg = regs[i]
        if not is_input then
          -- when creating an output list where the same register is used multiple times, the last one wins
          -- the other ones must be replaced with gaps as they get ignored
          if deduplicate_regs_lut[reg] then
            reg = il.gap_reg
          else
            deduplicate_regs_lut[reg] = true
          end
        end
        new_regs[i - start_index + 1] = reg
      end
      regs = new_regs
    end

    ---@type ILRegisterGroup
    local group = {
      inst = inst,
      regs = regs,
      is_input = is_input,
    }
    inst[is_input and "input_reg_group" or "output_reg_group"] = group

    for _, reg in ipairs(regs) do
      if reg.is_gap then goto continue end
      if not reg.reg_groups then
        reg.reg_groups = {group}
      else
        if not reg.is_parameter and not reg.requires_move_into_register_group then
          if reg.is_vararg then
            local prev_group = reg.reg_groups[#reg.reg_groups]
            set_forced_offset_for_groups(data, prev_group, group, #prev_group.regs - #group.regs)
          else
            link_register_groups(data, reg.reg_groups[1], group)
          end
        end
        reg.reg_groups[#reg.reg_groups+1] = group
      end
      ::continue::
    end

    if not group.linked_groups then
      -- create new linked groups
      group.linked_groups = {
        groups_lut = {[group] = true},
        groups = (nil)--[=[@as ILRegisterGroup[]]=], -- populated once all links are done
      }
      data.all_linked_groups_lut[group.linked_groups] = true
    end

    return group
  end

  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param ptrs ILPointer[]
  ---@param set_at_in_ptrs_func fun(func: ILFunction, inst: ILInstruction, ptr: ILPointer, index: integer?)
  local function expand_ptr_list(data, inst, ptrs, set_at_in_ptrs_func)
    for i, ptr in ipairs(ptrs) do
      if ptr.ptr_type ~= "reg" then
        local temp_reg = il.new_reg()
        il.insert_before_inst(data.func, inst, il.new_move{
          position = inst.position,
          right_ptr = ptr,
          result_reg = temp_reg,
        })
        set_at_in_ptrs_func(data.func, inst, temp_reg, i)
      end
    end
  end

  ---@type table<string, fun(data: ILCompilerData, inst: ILInstruction)>
  local inst_create_reg_group_lut = {
    ---@param data ILCompilerData
    ---@param inst ILSetList
    ["set_list"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs, il.set_at_in_right_ptrs)
      inst.right_ptrs[0] = inst.table_reg
      group_registers(data, inst, true, inst.right_ptrs, 0)
      inst.right_ptrs[0] = nil
    end,
    ---@param data ILCompilerData
    ---@param inst ILConcat
    ["concat"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs, il.set_at_in_right_ptrs)
      set_forced_offset_for_groups(
        data,
        group_registers(data, inst, true, inst.right_ptrs, 1),
        group_registers(data, inst, false, {inst.result_reg}, 1),
        0
      )
    end,
    ---@param data ILCompilerData
    ---@param inst ILCall
    ["call"] = function(data, inst)
      expand_ptr_list(data, inst, inst.arg_ptrs, il.set_at_in_arg_ptrs)
      inst.arg_ptrs[0] = inst.func_reg
      local input_group = group_registers(data, inst, true, inst.arg_ptrs, 0)
      inst.arg_ptrs[0] = nil
      local output_group = group_registers(data, inst, false, inst.result_regs, 1)
      set_forced_offset_for_groups(data, input_group, output_group, 0)
    end,
    ---@param data ILCompilerData
    ---@param inst ILRet
    ["ret"] = function(data, inst)
      if inst.ptrs[1] then
        expand_ptr_list(data, inst, inst.ptrs, il.set_at_in_ptrs)
        group_registers(data, inst, true, inst.ptrs, 1)
      end
    end,
    ---@param data ILCompilerData
    ---@param inst ILVararg
    ["vararg"] = function(data, inst)
      group_registers(data, inst, false, inst.result_regs, 1)
    end,
  }

  ---@param inst_group ILForprepGroup|ILForloopGroup
  local function validate_forprep_and_forloop_regs(inst_group)
    util.debug_assert(inst_group.index_reg ~= inst_group.limit_reg
        and inst_group.index_reg ~= inst_group.step_reg
        and inst_group.limit_reg ~= inst_group.step_reg,
      "The index, limit and step registers for forprep and forloop instruction groups must all be unique."
    )
    if inst_group.group_type == "forloop" then
      util.debug_assert(inst_group.local_reg ~= inst_group.index_reg
          and inst_group.local_reg ~= inst_group.limit_reg
          and inst_group.local_reg ~= inst_group.step_reg,
        "The index, limit, step and local registers for forloop instruction groups must all be unique."
      )
    end
  end
  local inst_group_create_reg_group_lut = {
    ["forprep"] = function(data, inst_group)
      validate_forprep_and_forloop_regs(inst_group)
      local regs = {inst_group.index_reg, inst_group.limit_reg, inst_group.step_reg}
      set_forced_offset_for_groups(
        data,
        group_registers(data, inst_group.start, true, regs, 1),
        group_registers(data, inst_group.stop, false, regs, 1),
        0
      )
    end,
    ["forloop"] = function(data, inst_group)
      validate_forprep_and_forloop_regs(inst_group)
      local input_regs = {inst_group.index_reg, inst_group.limit_reg, inst_group.step_reg}
      local output_regs = {inst_group.index_reg, il.gap_reg, il.gap_reg, inst_group.local_reg}
      set_forced_offset_for_groups(
        data,
        group_registers(data, inst_group.start, true, input_regs, 1),
        group_registers(data, inst_group.stop, false, output_regs, 1),
        0
      )
    end,
  }

  ---@type table<ILInstructionType, fun(func: ILFunction, inst: ILInstruction, reg_group: ILRegisterGroup, index_in_group: integer, reg: ILRegister)>
  local replace_reg_in_reg_group_inst_lut = {
    ---@param inst ILSetList
    ["set_list"] = function(func, inst, reg_group, index_in_group, reg)
      if index_in_group == 1 then -- the first one in the group must always be the table reg
        il.set_table_reg(func, inst, reg)
      else
        local index_in_right_ptrs = index_in_group - 1
        il.set_at_in_right_ptrs(func, inst, reg, index_in_right_ptrs)
      end
    end,
    ---@param inst ILConcat
    ["concat"] = function(func, inst, reg_group, index_in_group, reg)
      if reg_group.is_input then
        il.set_at_in_right_ptrs(func, inst, reg, index_in_group)
      else -- output reg group
        util.debug_assert(index_in_group == 1, "The output reg group of concat insts should only ever contain 1 reg.")
        il.set_result_reg(func, inst, reg)
      end
    end,
    ---@param inst ILCall
    ["call"] = function(func, inst, reg_group, index_in_group, reg)
      if reg_group.is_input then
        if index_in_group == 1 then -- the first one in the group must always be the func reg
          il.set_func_reg(func, inst, reg)
        else
          local index_in_arg_ptrs = index_in_group - 1
          il.set_at_in_arg_ptrs(func, inst, reg, index_in_arg_ptrs)
        end
      else -- output reg group
        il.set_at_in_result_regs(func, inst, reg, index_in_group)
      end
    end,
    ---@param inst ILRet
    ["ret"] = function(func, inst, reg_group, index_in_group, reg)
      il.set_at_in_ptrs(func, inst, reg, index_in_group)
    end,
    ---@param inst ILVararg
    ["vararg"] = function(func, inst, reg_group, index_in_group, reg)
      il.set_at_in_result_regs(func, inst, reg, index_in_group)
    end,
  }

  local replace_forprep_reg_lut = {
    [1] = il.replace_forprep_index_reg,
    [2] = il.replace_forprep_limit_reg,
    [3] = il.replace_forprep_step_reg,
  }

  local replace_forloop_reg_lut = {
    [1] = il.replace_forloop_index_reg,
    [2] = il.replace_forloop_limit_reg,
    [3] = il.replace_forloop_step_reg,
    [4] = il.replace_forloop_local_reg,
  }

  ---@param inst_group ILInstructionGroup
  ---@param reg_group ILRegisterGroup
  ---@return ILRegisterGroup
  local function get_opposite_reg_group_for_inst_group(inst_group, reg_group)
    return reg_group.is_input
      and inst_group.stop.output_reg_group--[[@as ILRegisterGroup]]
      or inst_group.start.input_reg_group--[[@as ILRegisterGroup]]
  end

  ---@param reg_group ILRegisterGroup
  ---@param index_in_group integer
  ---@param reg ILRegister
  local function mark_reg_as_replaced(reg_group, index_in_group, reg)
    -- if this function was called due to inst groups's reg groups being linked and using the same registers
    -- (which means that if a register gets replaced in one group, it also has to be replaced in the other
    -- one (the 2 groups in question are the input and output groups for inst groups))
    -- then we have to remember that this was an "implied" replacement to then inform future processing
    -- of this register group that a register was replaced so it can decide if it has to insert another
    -- move instruction to or from this register.
    -- this allows the input or output reg group for the inst group to be processed in any order, so long
    -- as they are not processed multiple times, because this extra data stored here cannot be cleaned up
    -- TODO: change this comment if the insert move logic can clean up all of the temp data
    local old_reg = reg_group.regs[index_in_group]
    reg_group.replaced_regs = reg_group.replaced_regs or {}
    reg_group.replaced_regs_lut = reg_group.replaced_regs_lut or {}
    if not reg_group.replaced_regs_lut[index_in_group] then
      reg_group.replaced_regs[#reg_group.replaced_regs+1] = {
        index = index_in_group,
        old_reg = old_reg,
      }
      reg_group.replaced_regs_lut[index_in_group] = old_reg
    end
    reg_group.regs[index_in_group] = reg
  end

  ---@type table<ILInstructionGroupType, fun(func: ILFunction, inst_group: ILInstructionGroup, reg_group: ILRegisterGroup, index_in_group: integer, reg: ILRegister)>
  local replace_reg_in_reg_group_inst_group_lut = {
    ---@param inst_group ILForprepGroup
    ["forprep"] = function(func, inst_group, reg_group, index_in_group, reg)
      -- both input and output have all 3 registers in the same location, so just do this regardless of that
      local replace_forprep_reg = replace_forprep_reg_lut[index_in_group]
      replace_forprep_reg(func, inst_group, reg)

      local opposite_reg_group = get_opposite_reg_group_for_inst_group(inst_group, reg_group)
      mark_reg_as_replaced(opposite_reg_group, index_in_group, reg)
    end,
    ---@param inst_group ILForloopGroup
    ["forloop"] = function(func, inst_group, reg_group, index_in_group, reg)
      -- both input and output have all 3 registers in the same location, so just do this regardless of that
      local replace_forloop_reg = replace_forloop_reg_lut[index_in_group]
      replace_forloop_reg(func, inst_group, reg)

      if index_in_group ~= 1 then return end -- only the first register is shared between the 2 reg groups
      local opposite_reg_group = get_opposite_reg_group_for_inst_group(inst_group, reg_group)
      mark_reg_as_replaced(opposite_reg_group, index_in_group, reg)
    end,
  }

  ---@param func ILFunction
  ---@param reg_group ILRegisterGroup
  ---@param index_in_group integer
  ---@param reg ILRegister
  local function replace_reg_in_reg_group(func, reg_group, index_in_group, reg)
    local inst = reg_group.inst
    if inst.inst_group then
      local group_type = inst.inst_group.group_type
      local replace_reg_in_reg_group_inst_group = replace_reg_in_reg_group_inst_group_lut[group_type]
      replace_reg_in_reg_group_inst_group(func, inst.inst_group, reg_group, index_in_group, reg)
    else
      local replace_reg_in_reg_group_inst = replace_reg_in_reg_group_inst_lut[inst.inst_type]
      replace_reg_in_reg_group_inst(func, inst, reg_group, index_in_group, reg)
    end

    reg_group.regs[index_in_group] = reg
  end

  ---@param data ILCompilerData
  local function create_register_groups(data)
    local inst = data.func.instructions.first
    while inst do
      if inst.inst_group then
        local inst_group_create_reg_group = inst_group_create_reg_group_lut[inst.inst_group.group_type]
        if inst_group_create_reg_group then
          inst_group_create_reg_group(data, inst.inst_group)
        end
        inst = inst.inst_group.stop.next
      else
        local inst_create_reg_group = inst_create_reg_group_lut[inst.inst_type]
        if inst_create_reg_group then
          inst_create_reg_group(data, inst)
        end
        inst = inst.next
      end
    end
  end

  ---@param linked_groups ILLinkedRegisterGroupsGroup
  local function populate_sorted_groups_list(linked_groups)
    linked_groups.groups = linq(util.iterate_keys(linked_groups.groups_lut))
      :sort(function(left, right)
        -- apparently it can ask if the same value that only exists once in the list should be
        -- positioned to the left of itself. It makes no sense, but I tested it and to make it
        -- a stable sort it must return false in this case. returning true or having the normal
        -- logic handle it makes it straight up put elements out of order
        if left == right then return false end
        if left.inst.index == right.inst.index then
          return left.is_input
        end
        return left.inst.index < right.inst.index
      end)
      :to_array()
    ;
  end

  ---@param data ILCompilerData
  ---@param linked_groups ILLinkedRegisterGroupsGroup
  local function split_linked_groups_recursive(data, linked_groups)
    -- the next part needs the first and last group, so we must create the ordered array
    populate_sorted_groups_list(linked_groups)

    -- find all regs and determine which require moves no matter what
    ---@type ILRegister[]
    local all_regs = {}
    local did_mark_a_new_register_to_require_move_into_register_group = false
    do
      local first_index = linked_groups.groups[1].inst.index
      local last_index = linked_groups.groups[#linked_groups.groups].inst.index
      for reg in linq(linked_groups.groups)
        :select_many(function(group) return group.regs end)
        :distinct()
        :where(function(reg) return not reg.is_gap end)
        :iterate()
      do
        all_regs[#all_regs+1] = reg

        -- TODO: somehow improve this condition to not leave big gaps in the stack
        if not reg.requires_move_into_register_group
          and (
            (reg.start_at.index < first_index and reg.stop_at.index > last_index)
              or reg.captured_as_upval
          )
        then
          reg.requires_move_into_register_group = true
          did_mark_a_new_register_to_require_move_into_register_group = true
        end
      end
    end

    if not did_mark_a_new_register_to_require_move_into_register_group then
      -- no registers that could cause the linked groups to split, just return
      return
    end

    -- make all registers forget what groups they were in
    for _, reg in ipairs(all_regs) do
      reg.reg_groups = nil
    end

    -- make the linked group no longer exist
    data.all_linked_groups_lut[linked_groups] = nil

    -- the next part cares about iteration order, the ordered array was already created though so nothing to do

    -- recreate all groups creating new links in the process
    local prev_group_has_forced_offset = false
    local prev_group
    local prev_offset_to_next_group
    for _, group in ipairs(linked_groups.groups) do
      local new_group = group_registers(data, group.inst, group.is_input, group.regs, 1)
      if prev_group_has_forced_offset then
        set_forced_offset_for_groups(data, prev_group, new_group, prev_offset_to_next_group)
        prev_group_has_forced_offset = false
      end
      if group.offset_to_next_group then
        prev_group_has_forced_offset = true
        prev_group = new_group
        prev_offset_to_next_group = group.offset_to_next_group
      end
    end

    -- this part doesn't care about iteration order, but it's using the ordered one anyway

    -- split all newly created groups again, unless only one new group was created
    local new_groups_count = 0
    local new_groups_lut = {}
    for _, group in ipairs(linked_groups.groups) do
      if not new_groups_lut[group.linked_groups] then
        -- but do process the first new group if a second new group is found
        if new_groups_count == 1 then
          split_linked_groups_recursive(data, (next(new_groups_lut)))
        end
        new_groups_lut[group.linked_groups] = true
        new_groups_count = new_groups_count + 1
        -- to prevent infinite recursion don't do anything for the first new group
        if new_groups_count ~= 1 then
          split_linked_groups_recursive(data, group.linked_groups)
        end
      end
    end
  end

  ---@param left ILInstruction
  ---@param right ILInstruction
  local function is_same_inst_group(left, right)
    if left.inst_group then
      return left.inst_group == right.inst_group
    else
      return left == right
    end
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  local function input_and_output_reg_index_is_the_same(inst, reg)
    local input_group = inst.inst_group and inst.inst_group.start.input_reg_group or inst.input_reg_group
    local output_group = inst.inst_group and inst.inst_group.start.output_reg_group or inst.output_reg_group

    if input_group and output_group then
      local offset = input_group.offset_to_next_group
      util.debug_assert(offset,
        "the input and output reg groups of an instruction or instruction group must be forcibly linked."
      )

      -- only take 2 because all we care about is if there are "none", "a single one" or "multiple"
      local count_in_input = linq(input_group.regs):where(function(r) return r == reg end):take(2):count()

      if count_in_input > 1 then
        return false
      end

      if count_in_input == 1 then
        local index_in_input = linq(input_group.regs):index_of(reg)
        local corresponding_reg_in_output = output_group.regs[index_in_input - offset]
        return corresponding_reg_in_output == reg
          or corresponding_reg_in_output.is_gap
          or (not corresponding_reg_in_output and not il.is_vararg_list(output_group.regs))
      end

      -- count_in_input == 0
      local index_in_output = linq(output_group.regs):index_of(reg)
      local corresponding_reg_in_input = input_group.regs[index_in_output + offset]
      return (corresponding_reg_in_input and corresponding_reg_in_input.is_gap)
        or (not corresponding_reg_in_input and not il.is_vararg_list(input_group.regs))
    end

    if input_group then
      -- only take 2 because all we care about is if there are "none", "a single one" or "multiple"
      return linq(input_group.regs):where(function(r) return r == reg end):take(2):count() == 1
    end

    return true
  end

  local determine_best_offsets
  do
    ---@param group ILRegisterGroup
    ---@param index_in_regs integer @
    ---must take the index, not the reg itself, because input groups can have the same register multiple times
    local function what_can_we_do(group, index_in_regs)
      local reg = group.regs[index_in_regs]
      ---@class DetermineBestOffsetsUnknownData
      ---@field lifetime_before integer
      ---@field lifetime_after integer
      ---@field use_in_place_as_soon_as_possible boolean
      local result = {
        group = group,
        reg = reg,
        index_in_regs = index_in_regs,
        usable_in_place = false,
        movable = true,
      }
      if reg.requires_move_into_register_group then
        return result
      end
      if group.is_input then
        if is_same_inst_group(group.inst, reg.stop_at) -- is this group the _last_ one using the register
          or input_and_output_reg_index_is_the_same(group.inst, reg) -- or input and output are the same index
          -- NOTE: if the next instruction (that isn't this one) that uses this register doesn't get its value
          -- but instead sets it then we could also use it in place here. No that's not something that should
          -- happen here, that should be a previous step during optimization, splitting the registers in 2
        then
          result.usable_in_place = true
        end
      else
        if is_same_inst_group(group.inst, reg.start_at) -- is this group the _first_ one using the register
          or input_and_output_reg_index_is_the_same(group.inst, reg) -- or input and output are the same index
        then
          result.usable_in_place = true
        end
      end
      return result
    end

    ---@param data ILCompilerData
    ---@param start_inst ILInstruction
    ---@param stop_inst ILInstruction
    local function count_instructions_from_to(data, start_inst, stop_inst)
      if start_inst.index > stop_inst.index then
        return 0
      end
      local result = 0
      for _ in il.iterate_insts_and_groups(data.func, start_inst, stop_inst) do
        result = result + 1
      end
      return result
    end

    ---@param reg ILRegister
    ---@param other_reg ILRegister
    local function register_lifetime_overlaps(reg, other_reg)
      return not ( -- the conditions below check if they are not overlapping, so just invert the whole result
        is_same_inst_group(reg.stop_at, other_reg.start_at)
          or is_same_inst_group(other_reg.stop_at, reg.start_at)
          or reg.stop_at.index < other_reg.start_at.index
          or other_reg.stop_at.index < reg.start_at.index
      )
    end

    ---@param data ILCompilerData
    ---@param linked_groups ILLinkedRegisterGroupsGroup
    function determine_best_offsets(data, linked_groups)
      ---@type DetermineBestOffsetsUnknownData[]
      local unknowns = {}
      ---@type DetermineBestOffsetsUnknownData[]
      local can_only_move = {}

      ---@type table<ILRegister, DetermineBestOffsetsUnknownData[]>
      local unknowns_by_reg = {}
      ---@type table<ILRegisterGroup, DetermineBestOffsetsUnknownData[]>
      local unknowns_by_group = {}

      local first_inst = linked_groups.groups[1].inst.prev
      local last_inst = linked_groups.groups[#linked_groups.groups].inst.next

      for i, group in ipairs(linked_groups.groups) do
        group.prev_group = linked_groups.groups[i - 1]
        group.next_group = linked_groups.groups[i + 1]
        if group.offset_to_next_group then
          group.next_group.offset_to_prev_group = -group.offset_to_next_group
        end
        unknowns_by_group[group] = {}

        for j = 1, #group.regs do
          local reg = group.regs[j]
          if reg.is_gap then goto continue end
          local unknown = what_can_we_do(group, j)
          unknown.lifetime_before = first_inst and count_instructions_from_to(data, reg.start_at, first_inst) or 0
          unknown.lifetime_after = last_inst and count_instructions_from_to(data, last_inst, reg.stop_at) or 0
          if unknown.usable_in_place then
            unknowns[#unknowns+1] = unknown
            unknowns_by_group[group][#unknowns_by_group[group]+1] = unknown
            unknowns_by_reg[reg] = unknowns_by_reg[reg] or {}
            unknowns_by_reg[reg][#unknowns_by_reg[reg]+1] = unknown
          else
            -- NOTE: currently useless
            can_only_move[#can_only_move+1] = unknown
          end
          ::continue::
        end
      end

      ---@type table<ILRegister, integer>
      local reg_indexes = {}
      ---@type table<integer, ILRegister[]>
      local regs_at_index_lut = {}
      ---@type type<ILRegisterGroup, integer>
      local group_indexes = {}
      local group_indexes_count = 0
      local total_moves_count = 0

      ---@type table<ILRegister, integer>
      local winning_reg_indexes
      ---@type table<ILRegisterGroup, integer>
      local winning_group_indexes
      local winning_score

      local set_reg_index
      ---@param group ILRegisterGroup
      ---@param group_index integer
      ---@param to_revert table @ state to pass to `revert_changes`
      ---@return boolean success
      local function set_group_index(group, group_index, to_revert)
        group_indexes[group] = group_index
        group_indexes_count = group_indexes_count + 1
        to_revert[#to_revert+1] = {
          type = "set_group_index",
          group = group,
        }
        local unknowns_for_group = unknowns_by_group[group]
        for _, unknown in ipairs(unknowns_for_group) do
          local reg_index = reg_indexes[unknown.reg]
          if reg_index then
            local current_group_index = reg_index - unknown.index_in_regs + 1
            if group_index ~= current_group_index then
              return false -- the already fixed index does not match the set group_index, abort set
            end
          else -- reg_index == nil
            if unknown.use_in_place_as_soon_as_possible
              and not set_reg_index(unknown.reg, group_index + unknown.index_in_regs - 1, to_revert)
            then
              return false
            end
          end
        end
        if group.offset_to_prev_group
          and not group_indexes[group.prev_group]
          and not set_group_index(group.prev_group, group_index + group.offset_to_prev_group, to_revert)
        then
          return false
        end
        if group.offset_to_next_group
          and not group_indexes[group.next_group]
          and not set_group_index(group.next_group, group_index + group.offset_to_next_group, to_revert)
        then
          return false
        end
        return true
      end

      ---@param reg ILRegister
      ---@param reg_index integer
      ---@param to_revert table @ state to pass to `revert_changes`
      ---@return boolean success
      function set_reg_index(reg, reg_index, to_revert)
        if reg.requires_move_into_register_group then
          util.debug_abort("Attempt to set index for a register that requires a move into register group.")
        end
        reg_indexes[reg] = reg_index
        local regs_at_index = regs_at_index_lut[reg_index]
        if not regs_at_index then
          regs_at_index = {}
          regs_at_index_lut[reg_index] = regs_at_index
        end
        regs_at_index[#regs_at_index+1] = reg
        for other_reg in linq(regs_at_index):skip_last(1):iterate() do
          if other_reg == reg then
            util.debug_abort("Calling set_reg_index for a register which already has a fixed index is not allowed.")
          end
          if register_lifetime_overlaps(reg, other_reg) then
            return false -- if they overlap, we can't use the same index
          end
        end

        to_revert[#to_revert+1] = {
          type = "set_reg_index",
          reg = reg,
        }
        local unknowns_for_reg = unknowns_by_reg[reg]
        for _, unknown in ipairs(unknowns_for_reg) do
          local group_index = group_indexes[unknown.group]
          if group_index then
            local current_reg_index = group_index + unknown.index_in_regs - 1
            if reg_index ~= current_reg_index then
              return false -- the already fixed index does not match the set reg_index, abort set
            end
          else -- group_index == nil
            if unknown.use_in_place_as_soon_as_possible
              and not set_group_index(unknown.group, reg_index - unknown.index_in_regs + 1, to_revert)
            then
              return false
            end
          end
        end
        return true
      end

      ---@param to_revert table
      local function revert_changes(to_revert)
        for i = #to_revert, 1, -1 do
          local action = to_revert[i]
          if action.type == "set_reg_index" then
            local reg_index = reg_indexes[action.reg]
            reg_indexes[action.reg] = nil
            local regs = regs_at_index_lut[reg_index]
            if regs[#regs] ~= action.reg then
              util.debug_abort(
                "The most recently set register should also be the last one in the array in regs_at_index_lut."
              )
            end
            -- keep the empty array around - if it ends up being empty -, good chance it'll be used again
            regs[#regs] = nil
          elseif action.type == "set_group_index" then
            group_indexes[action.group] = nil
            group_indexes_count = group_indexes_count - 1
          end
        end
      end

      local walk
      ---@param unknown DetermineBestOffsetsUnknownData
      ---@param i integer
      local function use_in_place(unknown, i)
        local group_index = group_indexes[unknown.group]
        if group_index then
          local correct_reg_index = group_index + unknown.index_in_regs - 1
          local reg_index = reg_indexes[unknown.reg]
          if reg_index then
            if reg_index ~= correct_reg_index then
              return -- the already fixed index does not match where it needs to be, invalid attempt
            end
            walk(i + 1)
            return
          end
          -- reg_index == nil

          -- this can force other groups to be at a fixed index. we must set said index
          -- additionally there might be registers that were already marked as "use in place" for
          -- those groups, but couldn't set their index yet, so we must set their index as well
          -- in doing so we might actually realize it's an invalid attempt and have to cleanup and early return
          local to_revert = {}
          if set_reg_index(unknown.reg, correct_reg_index, to_revert) then
            walk(i + 1)
          end
          -- unset the index of all registers and groups that were set by the previous logic
          revert_changes(to_revert)
          return
        end
        -- group_index == nil
        local reg_index = reg_indexes[unknown.reg]
        if reg_index then
          local to_revert = {}
          if set_group_index(unknown.group, reg_index - unknown.index_in_regs + 1, to_revert) then
            walk(i + 1)
          end
          revert_changes(to_revert)
        end
        -- we can't set the index of this register yet for its group doesn't have an index

        -- we must instead mark this register to be used in place once the group gets an index
        unknown.use_in_place_as_soon_as_possible = true
        walk(i + 1)
        -- unset the previously set flag
        unknown.use_in_place_as_soon_as_possible = nil
      end

      local move_score_weight = 32

      ---@param unknown DetermineBestOffsetsUnknownData
      ---@param i integer
      local function use_move(unknown, i)
        do
          local reg_index = reg_indexes[unknown.reg]
          local group_index = group_indexes[unknown.group]
          if reg_index and group_index and reg_index == group_index + unknown.index_in_regs - 1 then
            return -- it's already in-place, adding a move would make no sense
          end
        end
        if winning_score and (total_moves_count + 1) * move_score_weight > winning_score then
          return
        end
        total_moves_count = total_moves_count + 1
        walk(i + 1)
        total_moves_count = total_moves_count - 1
      end

      local attempt_count = 0

      local groups_count = #linked_groups.groups
      local function eval_score()
        attempt_count = attempt_count + 1
        print(attempt_count..": "..group_indexes_count.."/"..groups_count.." "
          ..(winning_score or "?").." vs "..(total_moves_count * move_score_weight)
        )
        if group_indexes_count ~= groups_count then return end
        -- TODO: take the amount and size of gaps into consideration when calculating score
        local score = total_moves_count * move_score_weight
        return score
      end

      local unknowns_count = #unknowns
      ---@param i integer
      function walk(i)
        if i > unknowns_count then
          local score = eval_score()
          if score and (not winning_score or score < winning_score) then
            winning_reg_indexes = util.shallow_copy(reg_indexes)
            winning_group_indexes = util.shallow_copy(group_indexes)
            winning_score = score
          end
          return
        end
        local unknown = unknowns[i]
        use_in_place(unknown, i)
        use_move(unknown, i)
      end

      set_group_index(linked_groups.groups[1], 0, {})
      walk(1)

      if not winning_score then
        util.debug_abort("Unable to determine register indexes for linked register groups because \z
          there are no solutions where all groups got assigned an index. This very most likely means \z
          that the groups aren't actually linked anymore. Some registers always require moves and \z
          those registers were the only ones keeping some groups linked with each other. \z
          Though maybe it is possible for them to be linked and there is no solution that can use \z
          registers in place in a way where all groups are linked, not sure."
        )
      end

      -- save the winning indexes on the registers
      local adjustment_index_offset = -linq(util.iterate_values(winning_group_indexes)):min()
      for _, group in ipairs(linked_groups.groups) do
        group.index_in_linked_groups = winning_group_indexes[group] + adjustment_index_offset
      end
      for reg in linq(linked_groups.groups)
        :select_many(function(group) return group.regs end)
        :distinct()
        :where(function(reg) return not reg.is_gap end)
        :iterate()
      do
        local relative_index = winning_reg_indexes[reg]
        if relative_index then
          reg.index_in_linked_groups = relative_index + adjustment_index_offset
        else
          reg.requires_move_into_register_group = true
        end
      end
    end
  end

  ---@param data ILCompilerData
  local function evaluate_indexes_for_regs_outside_of_groups(data)
    local empty = {}
    local used_reg_indexes = {}
    local used_reg_indexes_for_upvals = {}
    local top = -1

    local function use_reg(start_index)
      local index = start_index or 0
      while used_reg_indexes[index] do
        index = index + 1
      end
      used_reg_indexes[index] = true
      if index > top then
        top = index
      end
      return index
    end

    ---get lowest index above all currently alive regs for upvals
    local function use_reg_for_upval()
      local index = top
      while not used_reg_indexes_for_upvals[index] and index > 0 do -- this loop counts down to 0
        index = index - 1
      end
      index = use_reg(index)
      used_reg_indexes_for_upvals[index] = true
      return index
    end

    local function free_reg(index)
      used_reg_indexes[index] = nil
      used_reg_indexes_for_upvals[index] = nil
      while not used_reg_indexes[top] and top >= 0 do -- this loop counts down to -1
        top = top - 1
      end
    end

    for _, reg in ipairs(data.func.param_regs) do
      reg.predetermined_reg_index = use_reg()
    end

    for regs_for_inst in linq(ill.iterate_reverse(data.func.instructions)--[[@as fun(): ILInstruction?]])
      :group_by(function(inst) return inst.inst_group or inst end)
      :select(function(insts)
        return {
          starting_regs_iter = linq(insts)
            :select_many(function(inst) return inst.regs_start_at_list or empty end)
            :distinct()
            -- basically keeps all registers that don't have a fixed index in their linked register groups
            :where(function(reg) return not reg.is_internal
              and not reg.is_parameter
              and (not reg.reg_groups or reg.requires_move_into_register_group)
            end)
            :iterate()
          ,
          stopping_regs_iter = linq(insts)
            :select_many(function(inst) return inst.regs_stop_at_list or empty end)
            :distinct()
            -- basically keeps all registers that don't have a fixed index in their linked register groups
            :where(function(reg) return not reg.is_internal
              and not reg.is_parameter
              and (not reg.reg_groups or reg.requires_move_into_register_group)
            end)
            :select(function(reg, i) reg.index_for_order = i; return reg end)
            -- no special ordering for upvalues because doing so would create unnecessary gaps
            -- long lived registers first, putting them lower, resulting in less gaps
            :order_by(function(reg) return reg.start_at.index end)
            :then_by(function(reg) return reg.index_for_order end) -- to make it a stable & deterministic sort
            :select(function(reg) reg.index_for_order = nil; return reg end) -- cleanup
            :iterate()
          ,
        }
      end)
      :iterate()
    do
      local regs_to_instantly_free_again
      for reg in regs_for_inst.starting_regs_iter do
        if reg.predetermined_reg_index then
          free_reg(reg.predetermined_reg_index)
        else
          regs_to_instantly_free_again = regs_to_instantly_free_again or {}
          regs_to_instantly_free_again[reg] = true
          util.debug_print("Why and when do registers start and stop at the same instruction?")
        end
      end
      for reg in regs_for_inst.stopping_regs_iter do
        reg.predetermined_reg_index = reg.captured_as_upval and use_reg_for_upval() or use_reg()
        if regs_to_instantly_free_again and regs_to_instantly_free_again[reg] then
          free_reg(reg.predetermined_reg_index)
        end
      end
    end
  end

  ---@class ILMoveData
  ---@field from_index integer
  ---@field to_index integer
  ---@field reg ILRegister
  ---@field used boolean?

  ---@param linked_groups ILLinkedRegisterGroupsGroup
  ---@param reg_group ILRegisterGroup
  ---@return ILMoveData[] @
  ---Wether the `reg` is the source or the target of the move depends on if the group is an input or output
  ---group. If it is an input group, it is the source reg. If it is an output group, it is the target reg.
  local function get_moves_required_for_group(linked_groups, reg_group)
    local moves_data = {}
    local group_base_index = linked_groups.predetermined_base_index + reg_group.index_in_linked_groups
    local inside_index_key = reg_group.is_input and "to_index" or "from_index"
    local outside_index_key = reg_group.is_input and "from_index" or "to_index"
    local replaced_regs_lut = reg_group.replaced_regs_lut
    for i, reg in ipairs(reg_group.regs) do
      if reg.is_gap then goto continue end
      if replaced_regs_lut and replaced_regs_lut[i] then
        -- If the regs have already been replaced in this group due to it being forcibly linked with another
        -- group then we must use the register before it was replaced. This lookup table contains those regs.
        reg = replaced_regs_lut[i]
      end
      local inside_index = group_base_index + i - 1
      local outside_index = reg.predetermined_reg_index
      if inside_index ~= outside_index then
        moves_data[#moves_data+1] = {
          reg = reg,
          [inside_index_key] = inside_index,
          [outside_index_key] = outside_index,
        }
      end
      ::continue::
    end
    return moves_data
  end

  ---@param linked_groups ILLinkedRegisterGroupsGroup
  ---@param reg_group ILRegisterGroup
  ---@return ILMoveData[] non_circular_moves
  ---@return ILMoveData[] circular_moves @
  ---the intent is to move the first one in these arrays int a temp reg, then do the rest of the moves, and
  ---lastly move from the temp reg to the first one's target
  local function get_linked_moves_required_for_group(linked_groups, reg_group)
    -- 2 moves taking from the same register is more troublesome than expected.
    -- if 2 are taking from the same register then we cannot easily detect if it is circular or not. It's kind of like
    -- the register index becomes part of multiple move "trees" and even if there is one end with only 1 usage of
    -- a register, that doesn't mean there's a loop somewhere else, because the register that's read multiple times
    -- isn't free yet, therefore cannot be written to.
    local from_counts = {}
    local to_lut = {}
    local moves_with_free_target = {}

    local all_moves = get_moves_required_for_group(linked_groups, reg_group)
    for _, move in ipairs(all_moves) do
      from_counts[move.from_index] = (from_counts[move.from_index] or 0) + 1
      to_lut[move.to_index] = move

      if to_lut[move.from_index] and to_lut[move.from_index].index_in_moves_with_free_target then
        local other_move = to_lut[move.from_index]
        local i = other_move.index_in_moves_with_free_target
        local top_move = moves_with_free_target[#moves_with_free_target]
        top_move.index_in_moves_with_free_target = i
        moves_with_free_target[i] = top_move
        moves_with_free_target[#moves_with_free_target] = nil
        other_move.index_in_moves_with_free_target = nil
      end

      if not from_counts[move.to_index] then
        local i = #moves_with_free_target + 1
        moves_with_free_target[i] = move
        move.index_in_moves_with_free_target = i
      end
    end

    local non_circular_moves = {}
    for i, move in ipairs(moves_with_free_target) do
      local moves = {}
      non_circular_moves[i] = moves
      repeat
        moves[#moves+1] = move
        move.used = true
        if from_counts[move.from_index] > 1 then
          from_counts[move.from_index] = from_counts[move.from_index] - 1
        else
          move = to_lut[move.from_index]
        end
      until not move
    end

    local circular_moves = {}
    for _, move in ipairs(all_moves) do
      if move.used then goto continue end
      local moves = {move}
      circular_moves[#circular_moves+1] = moves
      local current_move = to_lut[move.from_index]
      repeat
        current_move.used = true
        moves[#moves+1] = current_move
        current_move = to_lut[current_move.from_index]
      until current_move == move
      ::continue::
    end

    return non_circular_moves, circular_moves
  end

  local insert_moves_in_and_out_of_reg_groups

  ---Also inserts move instructions otherwise it would position linked groups inside of each other
  ---because the temporary registers for move instructions are not allocated yet.
  ---@param data ILCompilerData
  ---@param linked_groups ILLinkedRegisterGroupsGroup
  local function determine_indexes_for_linked_groups(data, linked_groups)
    local empty = {}
    ---@param start_inst ILInstruction
    ---@param stop_inst ILInstruction
    local function get_highest_predetermined_index_in_range(start_inst, stop_inst)
      local start = il.get_inst_or_group(start_inst)
      local stop = il.get_inst_or_group(stop_inst)
      if start == stop then
        return linq(il.get_live_regs(start))
          :except_lut(il.get_regs_stop_at_list(start) or empty)
          :except_lut(il.get_regs_start_at_list(start) or empty)
          -- gaps don't exist in live_regs, but even if they did they'd just return -1
          :select(function(reg) return reg.predetermined_reg_index or -1 end)
          :default_if_empty(-1)
          :max()
        ;
      end

      return linq(il.get_live_regs(start))
        :except_lut(il.get_regs_stop_at_lut(start) or empty)
        :append(
          -- get_prev_inst_or_group because we don't want to include the regs that start at the last instruction.
          -- regs starting at start_inst are already included live_regs, but we can't skip it because that
          -- could cause the start instruction to be past the stop instruction for the iterator, so it would
          -- never reach the stop instruction resulting in an error.
          linq(il.iterate_insts_and_groups(data.func, start, il.get_prev_inst_or_group(stop)))
            :skip(1) -- the first one's start at list is already included in the initial live_regs
            -- we don't care when they stop
            :select_many(function(inst_or_group) return il.get_regs_start_at_list(inst_or_group) or empty end)
        )
        -- gaps don't exist in live_regs nor start at lists, but even if they did they'd just return -1
        :select(function(reg) return reg.predetermined_reg_index or -1 end)
        :default_if_empty(-1)
        :max()
      ;
    end

    local relevant_regs = linq(linked_groups.groups)
      :select_many(function(group) return group.regs end)
      :distinct()
      :where(function(reg) return reg.index_in_linked_groups and not reg.is_gap or false end)
      :to_array()
    ;

    local base_index = linq(relevant_regs)
      :select(function(reg) -- select the lowest index this register could be at
        return linq(reg.reg_groups)
          :where(function(reg_group)
            -- only check groups which are actually apart of this these linked groups
            -- and where the register doesn't require a move into the register list, so it is used in place
            return reg_group.linked_groups == linked_groups and linq(reg_group.regs):any(function(r, index)
              return r == reg and (reg_group.index_in_linked_groups + index - 1 == reg.index_in_linked_groups)
            end)
          end)
          :select(function(reg_group) -- it must have enough room under it in each group it is apart of
            return get_highest_predetermined_index_in_range(reg_group.inst, reg_group.inst)
              + 1 - reg.index_in_linked_groups
          end)
          :append{ -- and it must be above all other registers during its entire lifetime
            get_highest_predetermined_index_in_range(reg.start_at, reg.stop_at)
              + 1 - reg.index_in_linked_groups,
          }
          :max()
        ;
      end)
      -- to handle groups where all their registers require moves
      :append(linq(linked_groups.groups)
        :select(function(group)
          return get_highest_predetermined_index_in_range(group.inst, group.inst) + 1
        end)
      )
      :max()
    ;

    local function apply_base_index()
      linked_groups.predetermined_base_index = base_index
      for _, reg in ipairs(relevant_regs) do
        reg.predetermined_reg_index = base_index + reg.index_in_linked_groups
      end
    end
    apply_base_index()

    -- NOTE: the loop detection logic is entirely untested as of yet, because I can't easily create a test case.

    -- detect if there is a circular MOVE which will require a temp reg. If yes, increment base_index
    for _, group in ipairs(linked_groups.groups) do
      if linq(group.regs):any(function(reg) return reg.is_gap end)
        -- ^ There's a gap in the regs somewhere. If all non loop moves are done first then by the time any
        -- move loops have to move stuff around the gap will be free no matter what.
        or get_highest_predetermined_index_in_range(group.inst, group.inst) + 1 < base_index + group.index_in_linked_groups
        -- ^ there's room under the reg group
      then
        -- There is a free register for potential move loops to use, this group is fine as is. Next.
        goto continue
      end

      local _, circular_moves = get_linked_moves_required_for_group(linked_groups, group)
      if circular_moves[1] then
        base_index = base_index + 1
        apply_base_index()
        break
      end
      ::continue::
    end

    insert_moves_in_and_out_of_reg_groups(data, linked_groups)
  end

  ---@param data ILCompilerData
  ---@param linked_groups ILLinkedRegisterGroupsGroup
  ---@param reg_group ILRegisterGroup
  local function insert_moves_in_or_out_of_reg_group(data, linked_groups, reg_group)
    local temp_reg_index_for_circular_moves_cache
    local function get_temp_reg_index_for_circular_moves()
      if temp_reg_index_for_circular_moves_cache then
        return temp_reg_index_for_circular_moves_cache
      end
      local _, reg_index = linq(reg_group.regs):first(function(reg) return reg.is_gap end)
      if reg_index then
        -- minus 1 because reg_index is (naturally) 1 based, however 0 would be its real reg index
        reg_index = linked_groups.predetermined_base_index + reg_group.index_in_linked_groups + reg_index - 1
      else
        -- right before the group. it was previously ensured that there is space here
        reg_index = linked_groups.predetermined_base_index + reg_group.index_in_linked_groups - 1
      end
      temp_reg_index_for_circular_moves_cache = reg_index
      return reg_index
    end

    local inst_or_group = il.get_inst_or_group(reg_group.inst)

    local is_forprep_or_forloop_group_output = il.is_inst_group(inst_or_group)
      and (inst_or_group.group_type == "forprep" or inst_or_group.group_type == "forloop")
      and not reg_group.is_input

    -- inserting at main means inserting moves right before/after the inst the reg group is at
    local insert_at_main = not is_forprep_or_forloop_group_output

    -- inserting at secondary means inserting moves at the jump target of the inst the reg group is at
    -- therefore this only ever applies to output groups, if any.
    -- If it were to apply to input groups, then the inst reg group is at would have to be the jump target of
    -- other jumps, and since there aren't any Lua instructions that force me to do this, I can simply put the
    -- label those jumps before instruction group, and it'll all "just work".
    local insert_at_secondary = is_forprep_or_forloop_group_output

    local main_inst_to_insert_before = reg_group.is_input and reg_group.inst or reg_group.inst.next

    -- both nil when `insert_at_secondary` is `false`
    local secondary_inst_to_insert_before ---@type ILInstruction
    local jump_to_redirect ---@type ILJump|ILTest

    ---@param jump ILJump|ILTest
    local function set_jump_to_redirect(jump)
      jump_to_redirect = jump
      secondary_inst_to_insert_before = jump.label.next
    end

    if is_forprep_or_forloop_group_output then
      set_jump_to_redirect((inst_or_group--[[@as ILForloopGroup]]).loop_jump)
    end

    local function check_redirect_secondary_jump()
      if not insert_at_secondary or not jump_to_redirect.label.block.source_links[2] then return end

      -- if there are other jumps jumping to this label then we must
      local original_label = jump_to_redirect.label
      local label = il.new_label{position = original_label.position}
      il.insert_before_inst(data.func, original_label, label)
      il.set_jump_target(data.func, jump_to_redirect, label)
      set_jump_to_redirect(jump_to_redirect) -- set secondary_inst_to_insert_before

      -- if label.prev and linq(label.block.source_links):any(function(link)
      --   return link.source_block == label.prev.block
      -- end) then
      -- NOTE: duplication of block logic, may want to use the above logic instead, once possible
      if label.prev and (label.prev.inst_type ~= "jump" and label.prev.inst_type ~= "ret") then
        il.insert_before_inst(data.func, label, il.new_jump{
          position = original_label.position,
          label = original_label,
        })
      end
    end

    ---@param move ILMoveData
    ---@return ILRegister
    local function get_inserted_reg_in_group(move)
      -- this register will replace the reg in the register group.
      -- which means for input groups this is the target reg, for output groups this is the source reg
      local reg_index_in_group = reg_group.is_input and move.to_index or move.from_index
      -- plus 1 because we're converting zero based to one based
      local index_in_group = 1 + reg_index_in_group
        - (linked_groups.predetermined_base_index + reg_group.index_in_linked_groups)
      local reg_in_group
      if move.reg ~= reg_group.regs[index_in_group] then
        -- the reg has already been replaced in the reg group
        reg_in_group = reg_group.regs[index_in_group]
      else
        reg_in_group = il.new_reg()
        reg_in_group.predetermined_reg_index = reg_index_in_group
        replace_reg_in_reg_group(data.func, reg_group, index_in_group, reg_in_group)
      end
      return reg_in_group
    end

    ---@param moves ILMoveData[]
    local function insert_non_circular_linked_moves(moves, start_index)
      for i = start_index or 1, #moves do
        local move = moves[i]
        local inserted_reg_in_group = get_inserted_reg_in_group(move)

        if insert_at_main then
          il.insert_before_inst(data.func, main_inst_to_insert_before, il.new_move{
            position = reg_group.inst.position,
            right_ptr = reg_group.is_input and move.reg or inserted_reg_in_group,
            result_reg = reg_group.is_input and inserted_reg_in_group or move.reg,
          })
        end
        if insert_at_secondary then
          local disconnected_inserted_reg = il.new_reg()
          disconnected_inserted_reg.predetermined_reg_index = inserted_reg_in_group.predetermined_reg_index
          il.insert_before_inst(data.func, secondary_inst_to_insert_before, il.new_move{
            position = reg_group.inst.position,
            right_ptr = reg_group.is_input and move.reg or disconnected_inserted_reg,
            result_reg = reg_group.is_input and disconnected_inserted_reg or move.reg,
          })
        end
      end
    end

    ---@param moves ILMoveData[]
    local function insert_circular_linked_moves(moves)
      local first_move = moves[1]
      local inserted_reg_in_group = get_inserted_reg_in_group(first_move)

      local main_temp_reg
      if insert_at_main then
        main_temp_reg = il.new_reg()
        main_temp_reg.predetermined_reg_index = get_temp_reg_index_for_circular_moves()
        il.insert_before_inst(data.func, main_inst_to_insert_before, il.new_move{
          position = reg_group.inst.position,
          right_ptr = reg_group.is_input and first_move.reg or inserted_reg_in_group,
          result_reg = main_temp_reg,
        })
      end

      local secondary_temp_reg
      local disconnected_inserted_reg
      if insert_at_secondary then
        disconnected_inserted_reg = il.new_reg()
        disconnected_inserted_reg.predetermined_reg_index = inserted_reg_in_group.predetermined_reg_index
        secondary_temp_reg = il.new_reg()
        secondary_temp_reg.predetermined_reg_index = get_temp_reg_index_for_circular_moves()
        il.insert_before_inst(data.func, secondary_inst_to_insert_before, il.new_move{
          position = reg_group.inst.position,
          right_ptr = reg_group.is_input and first_move.reg or disconnected_inserted_reg,
          result_reg = secondary_temp_reg,
        })
      end

      insert_non_circular_linked_moves(moves, 2)

      if insert_at_main then
        il.insert_before_inst(data.func, main_inst_to_insert_before, il.new_move{
          position = reg_group.inst.position,
          right_ptr = main_temp_reg,
          result_reg = reg_group.is_input and inserted_reg_in_group or first_move.reg,
        })
      end

      if insert_at_secondary then
        il.insert_before_inst(data.func, secondary_inst_to_insert_before, il.new_move{
          position = reg_group.inst.position,
          right_ptr = secondary_temp_reg,
          result_reg = reg_group.is_input and disconnected_inserted_reg or first_move.reg,
        })
      end
    end

    local non_circular_moves, circular_moves = get_linked_moves_required_for_group(linked_groups, reg_group)
    if non_circular_moves[1] or circular_moves[1] then
      check_redirect_secondary_jump()

      for _, moves in ipairs(non_circular_moves) do
        insert_non_circular_linked_moves(moves)
      end
      for _, moves in ipairs(circular_moves) do
        insert_circular_linked_moves(moves)
      end
    end
  end

  ---@param data ILCompilerData
  ---@param linked_groups ILLinkedRegisterGroupsGroup
  function insert_moves_in_and_out_of_reg_groups(data, linked_groups)
    for _, reg_group in ipairs(linked_groups.groups) do
      insert_moves_in_or_out_of_reg_group(data, linked_groups, reg_group)
    end
  end

  ---Returns the highest `predetermined_reg_index` of all live register that don't start or stop at the given
  ---instruction. If there are none, returns `-1`.
  ---@param inst ILInstruction
  local function get_highest_reg_index_at_inst(inst)
    local empty = {}
    return linq(inst.live_regs)
      :except_lut(inst.regs_start_at_lut or empty)
      :except_lut(inst.regs_stop_at_lut or empty)
      :select(function(reg) return reg.predetermined_reg_index end)
      :default_if_empty(-1)
      :max()
  end

  ---@param data ILCompilerData
  ---@param inst ILNewTable|ILConcat|ILClosure
  ---@param current_top_index integer @
  ---give this the result of `get_highest_reg_index_at_inst` before any changes were made to inst
  local function change_result_reg_to_be_at_top(data, inst, current_top_index)
    local temp_reg = il.new_reg()
    temp_reg.predetermined_reg_index = current_top_index + 1
    il.insert_after_inst(data.func, inst, il.new_move{
      position = inst.position,
      right_ptr = temp_reg,
      result_reg = inst.result_reg,
    })
    il.set_result_reg(data.func, inst, temp_reg)
  end

  ---@type table<ILInstructionType, fun(data: ILCompilerData, inst: ILInstruction)?>
  local ensure_inst_is_at_top_lut = {
    ---@param inst ILNewTable
    ["new_table"] = function(data, inst)
      local top_index = get_highest_reg_index_at_inst(inst)
      if top_index <= inst.result_reg.predetermined_reg_index then return end
      change_result_reg_to_be_at_top(data, inst, top_index)
    end,
    ---@param inst ILConcat
    ["concat"] = function(data, inst)
      local top_index = get_highest_reg_index_at_inst(inst)
      if top_index <= inst.result_reg.predetermined_reg_index then return end

      -- this is a gigantic waste of move instructions and it should be handled differently. However I
      -- honestly don't know how exactly. note that linked groups do not enforce concats being at top in
      -- any way, neither does the logic position linked groups "relative to each other", which at the time
      -- of writing this is actually just iterating through all of them and putting them as low as possible
      -- with respect to all already positioned groups, and therefore their registers.

      for i = #inst.right_ptrs, 1, -1 do
        local old_reg = inst.right_ptrs[i]--[[@as ILRegister]]
        local temp_reg = il.new_reg()
        temp_reg.predetermined_reg_index = top_index + i
        il.insert_before_inst(data.func, inst, il.new_move{
          position = inst.position,
          right_ptr = old_reg,
          result_reg = temp_reg,
        })
        il.set_at_in_right_ptrs(data.func, inst, temp_reg, i)
      end

      change_result_reg_to_be_at_top(data, inst, top_index)
    end,
    ---@param inst ILClosure
    ["closure"] = function(data, inst)
      local top_index = get_highest_reg_index_at_inst(inst)
      if top_index <= inst.result_reg.predetermined_reg_index then return end
      change_result_reg_to_be_at_top(data, inst, top_index)
    end,
  }

  ---`new_table`, `concat` and `closure` run a garbage collection step above their result register after
  ---they are done. Therefore we must ensure that they are at the top of the stack.
  ---@param data ILCompilerData
  local function ensure_gc_insts_are_at_top(data)
    for inst_or_group in il.iterate_insts_and_groups(data.func) do
      if not il.is_inst_group(inst_or_group) then
        ---@cast inst_or_group ILInstruction
        local ensure_inst_is_at_top = ensure_inst_is_at_top_lut[inst_or_group.inst_type]
        if ensure_inst_is_at_top then
          ensure_inst_is_at_top(data, inst_or_group)
        end
      end
    end
  end

  ---@param data ILCompilerData
  function pre_compilation_process(data)
    create_register_groups(data)

    -- shallow copy because splitting ends up modifying the lut, but we need iterate the original
    for linked_groups in pairs(util.shallow_copy(data.all_linked_groups_lut)) do
      split_linked_groups_recursive(data, linked_groups)
    end

    -- populate groups list from groups_lut
    for linked_groups in pairs(data.all_linked_groups_lut) do
      if not linked_groups.groups then
        populate_sorted_groups_list(linked_groups)
      end
    end

    -- convert all_linked_groups_lut into a list
    local all_linked_groups = linq(util.iterate_keys(data.all_linked_groups_lut))
      :order_by(function(linked) return linked.groups[1].inst.index end)
      :to_array()
    ;

    -- determine best relative register indexes within linked groups
    for _, linked_groups in ipairs(all_linked_groups) do
      determine_best_offsets(data, linked_groups)
    end

    evaluate_indexes_for_regs_outside_of_groups(data)
    for _, linked_groups in ipairs(all_linked_groups) do
      determine_indexes_for_linked_groups(data, linked_groups) -- this also inserts move instructions
    end

    ensure_gc_insts_are_at_top(data)
  end
end

---@class ILCompilerData
---@field func ILFunction
---@field result CompiledFunc
-- ---@field stack table
---@field local_reg_count integer
---@field local_reg_gaps table<integer, true>
---While it starts off with both being nil, every function has at least 1 instruction,
---so `first` and `last` will be non nil real early and stay that way.
---@field compiled_instructions {first: ILCompiledInstruction, last: ILCompiledInstruction}
---@field compiled_registers ILCompiledRegister[]
---@field compiled_registers_count integer
---@field constant_lut table<number|string|boolean, integer>
---@field constants_count integer
---@field nil_constant_idx integer?
---@field nan_constant_idx integer?
---@field all_jumps (ILJump|ILTest)[]
---@field all_jumps_count integer
---@field all_linked_groups_lut table<ILLinkedRegisterGroupsGroup, true>

---@param func ILFunction
local function compile(func)
  func.is_compiling = true

  ---@type ILCompilerData
  local data = {
    func = func,
    local_reg_count = 0,
    local_reg_gaps = {},
    compiled_instructions = ll.new_list(),
    compiled_registers = {},
    compiled_registers_count = 0,
    constant_lut = {},
    constants_count = 0,
    all_jumps = {},
    all_jumps_count = 0,
    all_linked_groups_lut = {},
  }

  il.ensure_has_blocks(func)
  il.ensure_has_reg_liveliness(func)
  pre_compilation_process(data)

  data.result = make_bytecode_func(func)
  generate(data)

  for i = data.compiled_registers_count + 1, #data.compiled_registers do
    data.compiled_registers[i] = nil
  end
  for i = data.constants_count + 1, #data.result.constants do
    data.result.constants[i] = nil
  end
  for i = data.all_jumps_count + 1, #data.all_jumps do
    data.all_jumps[i] = nil
  end

  do
    local compiled_inst = data.compiled_instructions.first
    local result_instructions = data.result.instructions
    while compiled_inst do
      local index = #result_instructions + 1
      compiled_inst.inst_index = index
      result_instructions[index] = compiled_inst--[[@as Instruction]]
      compiled_inst = compiled_inst.next
    end
  end

  -- convert ILCompiledRegisters to CompiledRegisters
  for _, reg in ipairs(data.compiled_registers--[=[@as (ILCompiledRegister|CompiledRegister)[]]=]) do
    reg.index = reg.reg_index
    reg.reg_index = nil
    reg.start_at = reg.start_at.inst_index
    reg.stop_at = reg.stop_at and (reg.stop_at.inst_index - 1) or (#data.result.instructions)
  end
  data.result.debug_registers = data.compiled_registers

  for _, inst in ipairs(data.all_jumps) do
    inst.jump_inst.sbx = inst.label.target_inst.inst_index - inst.jump_inst.inst_index - 1
  end

  for i, inner_func in ipairs(func.inner_functions) do
    inner_func.closure_index = nil -- cleaning up as we go
    data.result.inner_functions[i] = compile(inner_func)
  end
  for _, upval in ipairs(func.upvals) do
    upval.upval_index = nil
  end

  func.is_compiling = false
  return data.result
end

return compile
