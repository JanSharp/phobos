
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local ill = require("indexed_linked_list")
local il = require("il_util")

local function determine_reg_usage(data)
  local inst = data.func.instructions.first
  while inst do
    il.determine_reg_usage_for_inst(inst)
    inst = inst.next
  end
end

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
  ---@param inst ILCompiledInstruction
  ---@param inserted_inst ILCompiledInstruction
  local function insert_inst(data, inst, inserted_inst)
    if not inst then
      add_inst(data, inserted_inst)
    else
      ill.insert_before(inst, inserted_inst)
    end
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
  ---@param inst ILCompiledInstruction
  ---@param position Position
  ---@param op Opcode
  ---@param args InstructionArguments
  ---@return ILCompiledInstruction inserted_inst
  local function insert_new_inst(data, inst, position, op, args)
    local inserted_inst = new_inst(data, position, op, args)
    insert_inst(data, inst, inserted_inst)
    return inserted_inst
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
    return {
      reg_index = reg_index,
      name = name,
      start_at = nil,
      stop_at = get_first_inst(data),
    }
  end

  ---@param data ILCompilerData
  local function create_new_temp_reg(data, name)
    local reg = create_compiled_reg(data, data.local_reg_count, name)
    data.local_reg_count = data.local_reg_count + 1
    return reg
  end

  ---@param data ILCompilerData
  ---@param reg ILCompiledRegister
  local function stop_reg(data, reg)
    data.local_reg_count = data.local_reg_count - 1
    if reg.reg_index ~= data.local_reg_count then
      util.debug_abort(
        "Attempt to close a register that is not at top.\n\z
        TODO: handle register shifting. Note that shifting of registers captured as upvalues is forbidden."
      )
    end
    reg.start_at = get_first_inst(data)
    data.compiled_registers[#data.compiled_registers+1] = reg
  end

  local generate_inst_lut
  local generate_inst
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

    local function stop_local_regs(data, inst)
      if not inst.regs_start_at_list then return end
      fill_regs_using_regs_list(inst.regs_start_at_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      sort_regs()
      for i = reg_count, 1, -1 do
        stop_reg(data, regs[i].current_reg)
        regs[i].temp_sort_index = nil
        regs[i] = nil
      end
    end

    local function start_local_regs(data, inst)
      if not inst.regs_stop_at_list then return end
      fill_regs_using_regs_list(inst.regs_stop_at_list)
      local reg_count = #regs
      if reg_count == 0 then return end
      sort_regs()
      local reg_index_to_close_upvals_from
      for i = 1, reg_count do
        local reg = regs[i]
        regs[i] = nil
        reg.current_reg = create_compiled_reg(data, data.local_reg_count + i - 1, reg.name)
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
      data.local_reg_count = data.local_reg_count + reg_count
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
  local function ensure_is_top_reg_pre(data, reg)
    if reg.reg_index >= data.local_reg_count - 1 then
      return reg
    else
      return create_new_temp_reg(data)
    end
  end

  ---@param data ILCompilerData
  ---@param initial_reg ILCompiledRegister
  ---@param top_reg ILCompiledRegister
  local function ensure_is_top_reg_post(data, position, initial_reg, top_reg)
    if top_reg ~= initial_reg then
      add_new_inst(data, position, opcodes.move, {
        a = initial_reg.reg_index,
        b = top_reg.reg_index,
      })
      stop_reg(data, top_reg)
    end
  end

  local function add_constant(data, ptr)
    -- NOTE: what does this mean: [...]
    -- unless const table is too big, then fetch into temporary (and emit warning: const table too large)
    -- (comment was from justarandomgeek originally in the binop function)

    if ptr.ptr_type == "nil" then
      if data.nil_constant_idx then
        return data.nil_constant_idx
      end
      data.nil_constant_idx = #data.result.constants
      data.result.constants[data.nil_constant_idx+1] = {node_type = "nil"}
      return data.nil_constant_idx
    end

    if ptr.value ~= ptr.value then
      if data.nan_constant_idx then
        return data.nan_constant_idx
      end
      data.nan_constant_idx = #data.result.constants
      data.result.constants[data.nan_constant_idx+1] = {node_type = "number", value = 0/0}
      return data.nan_constant_idx
    end

    if data.constant_lut[ptr.value] then
      return data.constant_lut[ptr.value]
    end
    local i = #data.result.constants
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
      return (ptr--[[@as ILRegister]]).current_reg
    else
      local k = add_constant(data, ptr)
      if k <= 0xff then
        return k
      end
      return create_new_temp_reg(data)
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
      return create_new_temp_reg(data)
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
    ["set_list"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
    end,
    ---@param inst ILNewTable
    ["new_table"] = function(data, inst)
      local reg = ensure_is_top_reg_pre(data, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.newtable, {
        a = reg.reg_index,
        b = util.number_to_floating_byte(inst.array_size),
        c = util.number_to_floating_byte(inst.hash_size),
      })
      ensure_is_top_reg_post(data, inst.position, inst.result_reg.current_reg, reg)
      return inst.prev
    end,
    ["concat"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
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
      data.all_jumps[#data.all_jumps+1] = inst
      return inst.prev
    end,
    ---@param inst ILTest
    ["test"] = function(data, inst)
      -- remember, generated from back to front, so the jump comes "first"
      inst.jump_inst = add_new_inst(data, inst.position, opcodes.jmp, {
        a = get_a_for_jump(inst),
        -- set after all instructions have been generated - once `inst_index`es have been evaluated
        sbx = (nil)--[[@as integer]],
      })
      data.all_jumps[#data.all_jumps+1] = inst
      local condition_reg = ref_or_load_ptr_pre(data, inst.condition_ptr)
      add_new_inst(data, inst.position, opcodes.test, {
        a = condition_reg.reg_index,
        c = inst.jump_if_true and 1 or 0,
      })
      ref_or_load_ptr_post(data, inst.position, inst.condition_ptr, condition_reg)
      return inst.prev
    end,
    ["call"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
    end,
    ["ret"] = function(data, inst)
      if inst.ptrs[1] then
        util.debug_abort("-- TODO: not implemented")
      else
        add_new_inst(data, inst.position, opcodes["return"], {a = 0, b = 1})
      end
      return inst.prev
    end,
    ---@param inst ILClosure
    ["closure"] = function(data, inst)
      local reg = ensure_is_top_reg_pre(data, inst.result_reg.current_reg)
      add_new_inst(data, inst.position, opcodes.closure, {
        a = reg.reg_index,
        bx = inst.func.closure_index,
      })
      ensure_is_top_reg_post(data, inst.position, inst.result_reg.current_reg, reg)
      return inst.prev
    end,
    ["vararg"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
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
    end
  end
end

---@param data ILCompilerData
local function make_bytecode_func(data)
  local func = data.func
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
        local_idx = upval.reg_in_parent_func.current_reg.reg_index,
      }
    elseif upval.parent_type == "upval" then
      result.upvals[i] = {
        index = 0,
        name = upval.name,
        in_stack = false,
        local_idx = upval.parent_upval.upval_index,
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

---@class ILCompilerData
---@field func ILFunction
---@field result CompiledFunc
-- ---@field stack table
---@field local_reg_count integer
---@field compiled_instructions IntrusiveIndexedLinkedList
---@field compiled_registers ILCompiledRegister[]
---@field constant_lut table<number|string|boolean, integer>
---@field all_jumps (ILJump|ILTest)[]

---@param func ILFunction
local function compile(func)
  local data = {func = func} ---@type ILCompilerData
  make_bytecode_func(data)
  determine_reg_usage(data)

  data.local_reg_count = 0
  data.compiled_instructions = ill.new(true)
  data.compiled_registers = {}
  data.constant_lut = {}
  data.all_jumps = {}
  generate(data)

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

  return data.result
end

return compile
