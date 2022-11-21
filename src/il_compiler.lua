
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local ill = require("indexed_linked_list")
local il = require("il_util")
local stack = require("stack")

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
    ill.prepend(data.compiled_instructions, inst)
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

  ---@class ILCompiledInstruction : IntrusiveILLNode, Instruction
  ---@field inst_index integer

  ---@param data ILCompilerData
  ---@return ILCompiledRegister
  local function create_compiled_reg(data, reg_index, name)
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
    return {
      reg_index = reg_index,
      name = name,
      start_at = nil,
      stop_at = get_first_inst(data),
    }
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
  end

  local generate_inst_lut
  local generate_inst_group_lut
  local generate_inst
  local generate_inst_group
  do
    ---@class ILRegisterWithTempSortIndex : ILRegister
    ---@field temp_sort_index integer

    local regs = {} ---@type ILRegisterWithTempSortIndex[]

    local function fill_regs_using_regs_list(list)
      for _, reg in ipairs(list) do
        reg.temp_sort_index = #regs + 1
        regs[reg.temp_sort_index] = reg
      end
    end

    local function sort_regs()
      table.sort(regs, function(left, right)
        if left.start_at.index ~= right.start_at.index then
          return left.start_at.index < right.start_at.index
        end
        if left.stop_at.index ~= right.stop_at.index then
          return left.start_at.index > right.start_at.index
        end
        -- to make it a stable sort
        return left.temp_sort_index < right.temp_sort_index
      end)
    end

    -- when reading these functions remember that we are generating from back to front

    ---@param data ILCompilerData
    ---@param reg_list ILRegister[]
    local function stop_local_regs_for_list(data, reg_list)
      fill_regs_using_regs_list(reg_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      table.sort(regs, function(left, right)
        return left.current_reg.reg_index > right.current_reg.reg_index
      end)
      -- sort_regs()
      for i = reg_count, 1, -1 do
        stop_reg(data, regs[i].current_reg)
        regs[i].temp_sort_index = nil
        regs[i] = nil
      end
    end

    local function stop_local_regs(data, inst)
      if inst.regs_start_at_list then
        stop_local_regs_for_list(data, inst.regs_start_at_list)
      end
    end

    ---@param data ILCompilerData
    ---@param position Position
    ---@param reg_list ILRegister[]
    local function start_local_regs_for_list(data, position, reg_list)
      fill_regs_using_regs_list(reg_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      sort_regs()
      local reg_index_to_close_upvals_from
      for i = 1, reg_count do
        local reg = regs[i]
        regs[i] = nil
        local reg_index = data.local_reg_count
        if next(data.local_reg_gaps) then
          reg_index = 0
          while not data.local_reg_gaps[reg_index] do
            reg_index = reg_index + 1
          end
        end
        reg.current_reg = create_compiled_reg(data, reg_index, reg.name)
        reg.temp_sort_index = nil
        if reg.captured_as_upval and not reg_index_to_close_upvals_from then
          reg_index_to_close_upvals_from = reg.current_reg.reg_index
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
    local function start_local_regs(data, inst)
      if not inst.regs_stop_at_list then return end
      start_local_regs_for_list(data, inst.position, inst.regs_stop_at_list)
    end

    ---@param inst_group ILInstructionGroup
    local function get_total_reg_start_and_stop_at_lists_for_inst_group(inst_group)
      local start_at_lut = {}
      local stop_at_lut = {}
      local inst = inst_group.start
      while inst ~= inst_group.stop.next do
        if inst.regs_start_at_list then
          for _, reg in ipairs(inst.regs_start_at_list) do
            start_at_lut[reg] = true
          end
        end
        if inst.regs_stop_at_list then
          for _, reg in ipairs(inst.regs_stop_at_list) do
            stop_at_lut[reg] = true
          end
      end
        inst = inst.next
      end
      local start_at_list = {}
      local stop_at_list = {}
      inst = inst_group.start
      while inst ~= inst_group.stop.next do
        if inst.regs_start_at_list then
          for _, reg in ipairs(inst.regs_start_at_list) do
            if not stop_at_lut[reg] then
              start_at_list[#start_at_list+1] = reg
            end
          end
        end
        if inst.regs_stop_at_list then
          for _, reg in ipairs(inst.regs_stop_at_list) do
            if not start_at_lut[reg] then
              stop_at_list[#stop_at_list+1] = reg
            end
          end
        end
        inst = inst.next
      end
      return start_at_list, stop_at_list
    end

    ---@param data ILCompilerData
    ---@param inst_group ILInstructionGroup
    function generate_inst_group(data, inst_group)
      local start_at_list, stop_at_list = get_total_reg_start_and_stop_at_lists_for_inst_group(inst_group)
      stop_local_regs_for_list(data, start_at_list)
      start_local_regs_for_list(data, inst_group.start.position, stop_at_list)
      return generate_inst_group_lut[inst_group.group_type](data, inst_group)
    end

    ---@param inst ILInstruction
    function generate_inst(data, inst)
      stop_local_regs(data, inst)
      start_local_regs(data, inst)
      return generate_inst_lut[inst.inst_type](data, inst)
    end
  end

  ---@param data ILCompilerData
  ---@param reg ILCompiledRegister
  ---@return ILCompiledRegister top_reg
  local function ensure_is_top_reg_for_set_pre(data, position, reg)
    if reg.reg_index >= data.local_reg_count - 1 then
      return reg
    else
      local temp_reg = create_new_reg_at_top(data)
      add_new_inst(data, position, opcodes.move, {
        a = reg.reg_index,
        b = temp_reg.reg_index,
      })
      return temp_reg
    end
  end

  ---@param data ILCompilerData
  ---@param initial_reg ILCompiledRegister
  ---@param top_reg ILCompiledRegister
  local function ensure_is_top_reg_for_set_post(data, initial_reg, top_reg)
    if top_reg ~= initial_reg then
      stop_reg(data, top_reg)
    end
  end

  ---@param data ILCompilerData
  ---@param reg ILCompiledRegister
  ---@return ILCompiledRegister top_reg
  local function ensure_is_exact_reg_for_get_pre(data, reg, reg_index)
    if reg.reg_index == reg_index then
      return reg
    else
      return create_compiled_reg(data, reg_index)
    end
  end

  ---@param data ILCompilerData
  ---@param initial_reg ILCompiledRegister
  ---@param exact_reg ILCompiledRegister
  local function ensure_is_exact_reg_for_get_post(data, position, initial_reg, exact_reg)
    if exact_reg ~= initial_reg then
      add_new_inst(data, position, opcodes.move, {
        a = exact_reg.reg_index,
        b = initial_reg.reg_index,
      })
      stop_reg(data, exact_reg)
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
      local table_reg_index = (inst.right_ptrs[1]--[[@as ILRegister]]).current_reg.reg_index - 1
      local table_reg = ensure_is_exact_reg_for_get_pre(data, inst.table_reg.current_reg, table_reg_index)
      add_new_inst(data, inst.position, opcodes.setlist, {
        a = table_reg_index,
        b = is_vararg and 0 or #inst.right_ptrs,
        c = ((inst.start_index - 1) / phobos_consts.fields_per_flush) + 1,
      })
      ensure_is_exact_reg_for_get_post(data, inst.position, inst.table_reg.current_reg, table_reg)
      return inst.prev
    end,
    ---@param inst ILNewTable
    ["new_table"] = function(data, inst)
      local reg = ensure_is_top_reg_for_set_pre(data, inst.position, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.newtable, {
        a = reg.reg_index,
        b = util.number_to_floating_byte(inst.array_size),
        c = util.number_to_floating_byte(inst.hash_size),
      })
      ensure_is_top_reg_for_set_post(data, inst.result_reg.current_reg, reg)
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
      -- TODO: Optimize by forcing registers to be at the right index and removing the moves in the [...]
      -- pre-process step (removing the `not reg.temporary` check, or so)
      local vararg_args = inst.arg_ptrs[1] and (inst.arg_ptrs[#inst.arg_ptrs]--[[@as ILRegister]]).is_vararg
      local vararg_result = inst.result_regs[1] and inst.result_regs[#inst.result_regs].is_vararg
      local func_reg_index = inst.register_list_index -- FIXME: rely on register groups
      local func_reg = ensure_is_exact_reg_for_get_pre(data, inst.func_reg.current_reg, func_reg_index)
      add_new_inst(data, inst.position, opcodes.call, {
        a = func_reg_index,
        b = vararg_args and 0 or (#inst.arg_ptrs + 1),
        c = vararg_result and 0 or (#inst.result_regs + 1),
      })
      ensure_is_exact_reg_for_get_post(data, inst.position, inst.func_reg.current_reg, func_reg)
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
      local reg = ensure_is_top_reg_for_set_pre(data, inst.position, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.closure, {
        a = reg.reg_index,
        bx = inst.func.closure_index,
      })
      ensure_is_top_reg_for_set_post(data, inst.result_reg.current_reg, reg)
      return inst.prev
    end,
    ---@param inst ILVararg
    ["vararg"] = function(data, inst)
      local is_vararg = inst.result_regs[#inst.result_regs].is_vararg
      add_new_inst(data, inst.position, opcodes.vararg, {
        a = inst.register_list_index, -- FIXME: rely on register groups
        b = is_vararg and 0 or (#inst.result_regs + 1),
      })
      return inst.prev
    end,
    ---@param inst ILCloseUp
    ["close_up"] = function(data, inst)
      -- TODO: ensure there are no other registers that are captured as upvalues above the ones closed here [...]
      -- this also needs to be done for all other places upvalues get closed (so for jumps and labels)
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
      )
    end,
  }

  generate_inst_group_lut = {
    ---@param data ILCompilerData
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
    ---@param data ILCompilerData
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
    ---@param data ILCompilerData
    ---@param inst_group ILTforcallGroup
    ["tforcall"] = function(data, inst_group)
      util.debug_abort("-- TODO: not implemented")
      return inst_group.start.prev
    end,
    ---@param data ILCompilerData
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

---@param data ILCompilerData
local function make_bytecode_func(data)
  local func = data.func
  if not func.has_reg_liveliness then
    il.eval_live_regs{func = func}
  end

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
  data.result = result
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
end

local pre_compilation_process
do
  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param regs ILRegister[]
  ---@param start_index integer @ start index in `regs`
  local function group_registers(data, inst, regs, start_index)
    -- pretty sure we don't need to do anything if the group would be an input group
    -- for an instruction past the end of the instruction list
    if not inst then return end
    -- TODO: impl
  end

  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param ptrs ILPointer[]
  local function expand_ptr_list(data, inst, ptrs)
    for i, ptr in ipairs(ptrs) do
      if ptr.ptr_type ~= "reg" then
        local temp_reg = il.new_reg()
        il.insert_before_inst(data.func, inst, il.new_move{
          position = inst.position,
          right_ptr = ptr,
          result_reg = temp_reg,
        })
        ptrs[i] = temp_reg
        il.add_reg_to_inst_get(data.func, inst, temp_reg)
      end
    end
  end

  ---@type table<string, fun(data: ILCompilerData, inst: ILInstruction)>
  local inst_pre_process_lut = {
    ---@param data ILCompilerData
    ---@param inst ILSetList
    ["set_list"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs)
      inst.right_ptrs[0] = inst.table_reg
      group_registers(data, inst, inst.right_ptrs, 0)
      inst.right_ptrs[0] = nil
    end,
    ---@param data ILCompilerData
    ---@param inst ILConcat
    ["concat"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs)
      -- TODO: where does the result_reg have to go
      group_registers(data, inst, inst.right_ptrs, 1)
    end,
    ---@param data ILCompilerData
    ---@param inst ILCall
    ["call"] = function(data, inst)
      expand_ptr_list(data, inst, inst.arg_ptrs)
      inst.arg_ptrs[0] = inst.func_reg
      group_registers(data, inst, inst.arg_ptrs, 0)
      inst.arg_ptrs[0] = nil
      group_registers(data, inst.next, inst.result_regs, 1)
    end,
    ---@param data ILCompilerData
    ---@param inst ILRet
    ["ret"] = function(data, inst)
      if inst.ptrs[1] then
        expand_ptr_list(data, inst, inst.ptrs)
        group_registers(data, inst, inst.ptrs, 1)
      end
    end,
    ---@param data ILCompilerData
    ---@param inst ILVararg
    ["vararg"] = function(data, inst)
      group_registers(data, inst.next, inst.result_regs, 1)
    end,
  }

  local inst_group_pre_process_lut = {
    ["forprep"] = function(data, inst_group)
      local regs = {inst_group.index_reg, inst_group.limit_reg, inst_group.step_reg}
      group_registers(data, inst_group.start, regs, 1)
      group_registers(data, inst_group.stop, regs, 1)
    end,
    ["forloop"] = function(data, inst_group)
      local regs = {inst_group.index_reg, inst_group.limit_reg, inst_group.step_reg}
      group_registers(data, inst_group.start, regs, 1)
      group_registers(data, inst_group.stop, regs, 1)
    end,
  }

  ---@param data ILCompilerData
  function pre_compilation_process(data)
    local inst = data.func.instructions.first
    while inst do
      if inst.inst_group then
        local inst_group_pre_process = inst_group_pre_process_lut[inst.inst_group.group_type]
        if inst_group_pre_process then
          inst_group_pre_process(data, inst.inst_group)
        end
        inst = inst.inst_group.stop.next
      else
        local inst_pre_process = inst_pre_process_lut[inst.inst_type]
        if inst_pre_process then
          inst_pre_process(data, inst)
        end
        inst = inst.next
      end
    end
  end
end

---@class ILCompilerDataSnapshot
---@field first_inst ILCompiledInstruction
---@field compiled_registers_count integer
---@field local_reg_gaps table<integer, true>
---@field local_reg_count integer
---@field constants_count integer
---@field nil_constant_idx integer?
---@field nan_constant_idx integer?
---@field all_jumps (ILJump|ILTest)[]
---@field max_stack_size integer
---@field current_inst ILInstruction

---@class ILCompilerData
---@field func ILFunction
---@field result CompiledFunc
-- ---@field stack table
---@field local_reg_count integer
---@field local_reg_gaps table<integer, true>
---@field compiled_instructions IntrusiveIndexedLinkedList
---@field compiled_registers ILCompiledRegister[]
---@field compiled_registers_count integer
---@field constant_lut table<number|string|boolean, integer>
---@field constants_count integer
---@field nil_constant_idx integer?
---@field nan_constant_idx integer?
---@field all_jumps (ILJump|ILTest)[]
---@field all_jumps_count integer
---@field snapshots ILCompilerDataSnapshot[]

---@param func ILFunction
local function compile(func)
  ---@type ILCompilerData
  local data = {
    func = func,
    local_reg_count = 0,
    local_reg_gaps = {},
    compiled_instructions = ill.new(true),
    compiled_registers = {},
    compiled_registers_count = 0,
    constant_lut = {},
    constants_count = 0,
    all_jumps = {},
    all_jumps_count = 0,
    snapshots = stack.new_stack(),
  }
  func.is_compiling = true
  make_bytecode_func(data)
  il.determine_reg_usage(func)
  pre_compilation_process(data)

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

  for _, reg in ipairs(data.compiled_registers) do
    ---@cast reg ILCompiledRegister|CompiledRegister
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
