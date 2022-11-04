
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local ill = require("indexed_linked_list")
local il = require("il_util")
local stack = require("stack")

local generate
do
  local restore_last_snapshot = false
  local forced_list_index_shift = 0

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

  ---@param data ILCompilerData
  ---@param current_inst ILInstruction
  local function take_snapshot(data, current_inst)
    ---@type ILCompilerDataSnapshot
    local snapshot = {
      first_inst = get_first_inst(data),
      compiled_registers_count = data.compiled_registers_count,
      local_reg_gaps = util.shallow_copy(data.local_reg_gaps),
      local_reg_count = data.local_reg_count,
      constants_count = data.constants_count,
      nil_constant_idx = data.nil_constant_idx,
      nan_constant_idx = data.nan_constant_idx,
      all_jumps = util.shallow_copy(data.all_jumps),
      max_stack_size = data.result.max_stack_size,
      current_inst = current_inst,
    }
    stack.push(data.snapshots, snapshot)
  end

  ---@param data ILCompilerData
  ---@return ILInstruction
  local function load_snapshot(data)
    local snapshot = stack.pop(data.snapshots)
    util.debug_assert(snapshot, "Attempt to load a snapshot when there are no snapshots on the stack.")
    while snapshot.first_inst.prev do
      ill.remove(snapshot.first_inst.prev)
    end
    for i = snapshot.constants_count, data.constants_count - 1 do
      local constant = data.result.constants[i]
      data.constant_lut[constant.index] = nil
      -- data.result.constants[i] = nil -- no need because after it's done generating it gets cleaned up
    end
    data.compiled_registers_count = snapshot.compiled_registers_count
    data.local_reg_gaps = snapshot.local_reg_gaps
    data.local_reg_count = snapshot.local_reg_count
    data.constants_count = snapshot.constants_count
    data.nil_constant_idx = snapshot.nil_constant_idx
    data.nan_constant_idx = snapshot.nan_constant_idx
    data.all_jumps = snapshot.all_jumps
    data.result.max_stack_size = snapshot.max_stack_size
    return snapshot.current_inst
  end

  local take_snapshots_before_types_lut = util.invert{
    "set_list",
    "call",
    "ret",
  }

  local insts_with_forced_list_index_lut = util.invert{
    "set_list",
    "concat",
    "call",
    "ret",
  }

  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param list_index_shift integer
  local function setup_for_restoring_snapshot(data, inst, list_index_shift)
    restore_last_snapshot = true
    forced_list_index_shift = list_index_shift
    if take_snapshots_before_types_lut[inst.inst_type] then
      -- prevent infinite loops, since the snapshot for this instruction is taken before
      -- any function that might want to restore a prior snapshot is called for this instruction
      stack.pop(data.snapshots)
    end
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
  local generate_inst
  do
    ---@param data ILCompilerData
    ---@param inst ILCall|ILVararg
    local function fix_register_indexes(data, inst)
      local top_reg_index = data.local_reg_count
      local reg_count = #inst.result_regs

      -- if inst.inst_type == "call" and inst.func_reg.stop_at ~= inst then
      --   top_reg_index = top_reg_index + 1
      -- end

      -- TODO: use a gap instead of making a new temp reg if there is a temp reg

      -- TODO: detect which register indexes would require the least amount of moves

      local last_reg = inst.result_regs[#inst.result_regs]
      local is_vararg = last_reg and last_reg.is_vararg

      local register_list_index
      local has_temp_reg = false
      if is_vararg then
        register_list_index = last_reg.current_reg.reg_index - #inst.result_regs + 1
        if register_list_index > top_reg_index then
          has_temp_reg = true
        elseif register_list_index < top_reg_index then
          -- modifies forced_list_index by setting a shift that's applied later
          setup_for_restoring_snapshot(data, inst, register_list_index - top_reg_index)
          return
        end
      else
        register_list_index = top_reg_index
      end
      ::do_it_again::

      ---@type table<integer, true?>
      local free_register_indexes_lut = {[top_reg_index] = has_temp_reg or nil}
      ---@type table<integer, {is_done: boolean, is_loop: boolean, moves: {source_reg: integer, target_reg: integer}[]}>
      local loop_or_chain_reg_lut = {}
      local reg_moving_into_top_reg_index = nil

      local function is_free_target_index(reg_index)
        -- moving into a register that is still alive past this instruction, it's a downwards move
        return reg_index < register_list_index
          or reg_index >= register_list_index + reg_count -- detect upwards moves
      end

      local function check_for_loop(reg_index)
        local current_reg_index = reg_index
        while not is_free_target_index(current_reg_index) do
          local result_reg_index = current_reg_index - register_list_index + 1
          current_reg_index = inst.result_regs[result_reg_index].current_reg.reg_index
          if current_reg_index == reg_index then return true end
        end
        return false
      end

      local function add_loop_or_chain(first_reg_index, is_loop, stop_condition)
        local current_reg_index = first_reg_index
        local moves = {}
        local loop = {is_loop = is_loop, moves = moves}
        repeat
          loop_or_chain_reg_lut[current_reg_index] = loop
          local result_reg_index = current_reg_index - register_list_index + 1
          local move_data = {source_reg = current_reg_index}
          current_reg_index = inst.result_regs[result_reg_index].current_reg.reg_index
          move_data.target_reg = current_reg_index
          moves[#moves+1] = move_data
        until stop_condition(current_reg_index)
      end

      local function add_loop(first_reg_index)
        add_loop_or_chain(first_reg_index, true, function(current_reg_index)
          return current_reg_index == first_reg_index
        end)
      end

      local function add_chain(first_reg_index)
        add_loop_or_chain(first_reg_index, false, function(current_reg_index)
          return is_free_target_index(current_reg_index)
        end)
      end

      for i, reg in ipairs(inst.result_regs) do
        local current_reg_index = register_list_index + i - 1
        if loop_or_chain_reg_lut[current_reg_index] then goto continue end
        if is_free_target_index(current_reg_index) then
          if has_temp_reg and reg.current_reg.reg_index == top_reg_index then
            reg_moving_into_top_reg_index = current_reg_index
          else
            free_register_indexes_lut[current_reg_index] = true
          end
        elseif reg.current_reg.reg_index ~= current_reg_index
          and not free_register_indexes_lut[reg.current_reg.reg_index]
        then
          -- check if this is actually a loop
          if check_for_loop(current_reg_index) then
            if not has_temp_reg then
              if is_vararg then
                setup_for_restoring_snapshot(data, inst, 1)
                return
              end
              has_temp_reg = true
              register_list_index = register_list_index + 1
              -- now that it requires a temp reg, it has to start over since all registers have been shifted
              goto do_it_again
            end
            -- it's a loop
            add_loop(current_reg_index)
          else
            -- it's just a chain ending in a free move, not a loop
            add_chain(current_reg_index)
          end
        end
        ::continue::
      end

      if reg_moving_into_top_reg_index then
        add_new_inst(data, inst.position, opcodes.move, {
          a = top_reg_index,
          b = reg_moving_into_top_reg_index,
        })
      end

      for i = reg_count, 1, -1 do
        local reg = inst.result_regs[i]
        local current_reg_index = register_list_index + i - 1
        if current_reg_index == reg_moving_into_top_reg_index then goto continue end
        local loop_or_chain = loop_or_chain_reg_lut[current_reg_index]
        if loop_or_chain then
          if loop_or_chain.is_done then goto continue end
          if loop_or_chain.is_loop then -- loop
            local moves = loop_or_chain.moves
            local last_move = moves[#moves]
            add_new_inst(data, inst.position, opcodes.move, {
              a = last_move.target_reg,
              b = top_reg_index,
            })
            for j = 1, #moves - 1 do
              local move = loop_or_chain.moves[j]
              add_new_inst(data, inst.position, opcodes.move, {
                a = move.target_reg,
                b = move.source_reg,
              })
            end
            add_new_inst(data, inst.position, opcodes.move, {
              a = top_reg_index,
              b = last_move.source_reg,
            })
          else -- chain
            for j = #loop_or_chain.moves, 1, -1 do
              local move = loop_or_chain.moves[j]
              add_new_inst(data, inst.position, opcodes.move, {
                a = move.target_reg,
                b = move.source_reg,
              })
            end
          end
          loop_or_chain.is_done = true
        elseif reg.current_reg.reg_index ~= current_reg_index then
          -- everything that isn't in a loop or chain is a simple move
          add_new_inst(data, inst.position, opcodes.move, {
            a = reg.current_reg.reg_index,
            b = current_reg_index,
          })
        end
        ::continue::
      end

      inst.register_list_index = register_list_index
    end

    local fix_register_indexes_lut = util.invert{
      "call",
      "vararg",
    }

    ---@param data ILCompilerData
    ---@param inst ILSetList|ILConcat|ILCall|ILRet
    ---@param regs ILRegister[]
    local function restrict_register_list(data, inst, regs)
      local list_index = inst.forced_list_index
      for i, reg in ipairs(regs) do
        util.debug_assert(reg.ptr_type == "reg", "The pre process should change all ptrs to regs.")
        -- util.debug_assert(not reg.current_reg, "All registers for lists")
        reg.current_reg = create_compiled_reg(data, list_index + i - 1, reg.name)
      end
    end

    ---@type table<string, fun(data: ILCompilerData, inst: ILInstruction)>
    local restrict_register_indexes_lut = {
      ---@param data ILCompilerData
      ---@param inst ILSetList
      ["set_list"] = function(data, inst)
        inst.forced_list_index = inst.forced_list_index or (data.local_reg_count + 1)
        if inst.table_reg.stop_at == inst then
          inst.table_reg.current_reg = create_compiled_reg(
            data,
            inst.forced_list_index - 1,
            inst.table_reg.name
          )
        end
        restrict_register_list(data, inst, inst.right_ptrs)
      end,
      ---@param data ILCompilerData
      ---@param inst ILConcat
      ["concat"] = function(data, inst)
        inst.forced_list_index = inst.forced_list_index or data.local_reg_count
        restrict_register_list(data, inst, inst.right_ptrs)
      end,
      ---@param data ILCompilerData
      ---@param inst ILCall
      ["call"] = function(data, inst)
        inst.forced_list_index = inst.forced_list_index or (inst.register_list_index + 1)
        if inst.func_reg.stop_at == inst then
          inst.func_reg.current_reg = create_compiled_reg(
            data,
            inst.forced_list_index - 1,
            inst.func_reg.name
          )
        end
        restrict_register_list(data, inst, inst.arg_ptrs)
      end,
      ---@param data ILCompilerData
      ---@param inst ILRet
      ["ret"] = function(data, inst)
        if inst.ptrs then
          inst.forced_list_index = inst.forced_list_index or data.local_reg_count
          restrict_register_list(data, inst, inst.ptrs)
        else
          stack.pop(data.snapshots) -- NOTE: what a waste of performance, but it doesn't happen often
        end
      end,
      ---@param data ILCompilerData
      ---@param inst ILVararg
      ["vararg"] = function(data, inst)
        util.debug_abort("Impossible because no registers should ever stop at an ILVararg instruction.")
      end,
    }

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

    local function stop_local_regs(data, inst)
      if inst.regs_start_at_list then
        fill_regs_using_regs_list(inst.regs_start_at_list)
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
      if fix_register_indexes_lut[inst.inst_type] then
        fix_register_indexes(data, inst)
      end
    end

    ---@param data ILCompilerData
    ---@param inst ILInstruction
    local function start_local_regs(data, inst)
      if not inst.regs_stop_at_list then return end

      if restrict_register_indexes_lut[inst.inst_type] then
        restrict_register_indexes_lut[inst.inst_type](data, inst)
        for _, reg in ipairs(inst.regs_stop_at_list) do
          util.debug_assert(reg.current_reg, "restrict_register_indexes_lut must create regs \z
            for all registers that stop at this instruction."
          )
        end
      else
        fill_regs_using_regs_list(inst.regs_stop_at_list)
        local reg_count = #regs
        if reg_count == 0 then return end
        sort_regs()
        local reg_index_to_close_upvals_from
        for i = 1, reg_count do
          local reg = regs[i]
          regs[i] = nil
          reg.current_reg = create_compiled_reg(data, data.local_reg_count, reg.name)
          reg.temp_sort_index = nil
          if reg.captured_as_upval and not reg_index_to_close_upvals_from then
            reg_index_to_close_upvals_from = reg.current_reg.reg_index
          end
        end
        -- do this after all regs have been created - all regs are alive - for nice and clean debug symbols
        if reg_index_to_close_upvals_from then
          add_new_inst(data, inst.position, opcodes.jmp, {
            a = reg_index_to_close_upvals_from + 1,
            sbx = 0,
          })
        end
      end
    end

    ---@param inst ILInstruction
    function generate_inst(data, inst)
      if take_snapshots_before_types_lut[inst.inst_type] then
        take_snapshot(data, inst)
      end
      stop_local_regs(data, inst)
      if restore_last_snapshot then return end -- early returns, wouldn't want to waste performance
      start_local_regs(data, inst)
      if restore_last_snapshot then return end -- same here
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
        add_new_inst(data, inst.position, opcodes.move, {
          a = inst.result_reg.current_reg.reg_index,
          b = (inst.right_ptr--[[@as ILRegister]]).current_reg.reg_index,
        })
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
      local func_reg_index = inst.register_list_index
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
        a = inst.register_list_index,
        b = is_vararg and 0 or (#inst.result_regs + 1),
      })
      return inst.prev
    end,
    ["scoping"] = function(data, inst)
      -- no op
      return inst.prev
    end,
  }

  function generate(data)
    local inst = data.func.instructions.last
    while inst do
      inst = generate_inst(data, inst)
      if restore_last_snapshot then
        restore_last_snapshot = false
        inst = load_snapshot(data)
        if insts_with_forced_list_index_lut[inst.inst_type] then
          inst.forced_list_index = inst.forced_list_index + forced_list_index_shift
        end
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

local expand_ptr_lists
do
  ---@param data ILCompilerData
  ---@param inst ILInstruction
  ---@param ptrs ILPointer[]
  local function expand_ptr_list(data, inst, ptrs)
    local regs_lut = {}
    local regs_count = 0
    for i, ptr in ipairs(ptrs) do
      if ptr.ptr_type == "reg" then
        if not regs_lut[ptr] then
          regs_count = regs_count + 1
          regs_lut[ptr] = true
        end
      else
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

    ---@type table<ILRegister, ILInstruction>
    local reg_setter_lut = {}
    local prev_inst = inst.prev
    while regs_count > 0 do
      util.debug_assert(prev_inst, "Impossible because there must be an instruction setting every \z
        register that comes before an instruction using a register."
      ) ---@cast prev_inst -nil
      il.visit_regs_for_inst(nil, prev_inst, function(_, _, reg, get_set)
        if regs_lut[reg] and bit32.band(get_set, 2) ~= 0 then
          regs_count = regs_count - 1
          regs_lut[reg] = nil
          reg_setter_lut[reg] = prev_inst
        end
      end)
      prev_inst = prev_inst.prev
    end

    -- TODO: think about this a bit more. I think it's functional but there are probably some improvements
    ---@type ILInstruction
    local prev_setter_inst
    for i, reg in pairs(ptrs) do
      ---@cast reg ILRegister
      local setter_inst = reg_setter_lut[reg]
      if setter_inst then
        if not reg.temporary or prev_setter_inst and setter_inst.index < prev_setter_inst.index then
          if reg.is_vararg then
            util.debug_abort("Impossible because there must be no instructions between an instruction \z
              setting a vararg register and an instruction consuming a vararg register \z
              before expanding register lists. (Note that it might be possible to simply ignore vararg \z
              registers for this expansion logic here and have the snapshot logic during compilation take \z
              care of it. That mostly applies if I remove the restriction of 'no insts between these 2' \z
              that was mentioned previously.)"
            )
          end
          local temp_reg = il.new_reg()
          il.insert_after_inst(data.func, setter_inst, il.new_move{
            position = inst.position,
            right_ptr = reg,
            result_reg = temp_reg,
          })
          ptrs[i] = temp_reg
          il.remove_reg_from_inst_get(data.func, inst, reg)
          il.add_reg_to_inst_get(data.func, inst, temp_reg)
        end
        prev_setter_inst = setter_inst
      end
    end
  end

  ---@type table<string, fun(data: ILCompilerData, inst: ILInstruction)>
  local expand_ptr_list_lut = {
    ---@param data ILCompilerData
    ---@param inst ILSetList
    ["set_list"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs)
    end,
    ---@param data ILCompilerData
    ---@param inst ILConcat
    ["concat"] = function(data, inst)
      expand_ptr_list(data, inst, inst.right_ptrs)
    end,
    ---@param data ILCompilerData
    ---@param inst ILCall
    ["call"] = function(data, inst)
      expand_ptr_list(data, inst, inst.arg_ptrs)
    end,
    ---@param data ILCompilerData
    ---@param inst ILRet
    ["ret"] = function(data, inst)
      if inst.ptrs[1] then
        expand_ptr_list(data, inst, inst.ptrs)
      end
    end,
    -- nothing to do for vararg, it only outputs a list of registers, doesn't take an input
  }

  ---@param data ILCompilerData
  function expand_ptr_lists(data)
    local inst = data.func.instructions.first
    while inst do
      local expand_ptrs = expand_ptr_list_lut[inst.inst_type]
      if expand_ptrs then
        expand_ptrs(data, inst)
      end
      inst = inst.next
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
  expand_ptr_lists(data)

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
