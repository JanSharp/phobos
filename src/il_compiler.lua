
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local ill = require("indexed_linked_list")

local determine_reg_usage
do
  local get = true
  local set = false
  local both = nil

  local function visit_reg(data, inst, reg, get_set)
    reg.total_get_count = reg.total_get_count or 0
    reg.total_set_count = reg.total_set_count or 0
    if get_set ~= set then
      reg.total_get_count = reg.total_get_count + 1
    end
    if get_set ~= get then
      reg.total_set_count = reg.total_set_count + 1
    end
  end

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
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack if this is a concat
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
    ["closure"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack
    end,
    ["vararg"] = function(data, inst)
      visit_reg_list(data, inst, inst.result_regs, set) -- must be in order
    end,
    ["scoping"] = function(data, inst)
      visit_reg_list(data, inst, inst.regs, both)
    end,
  }

  function determine_reg_usage(data)
    local inst = data.func.instructions.first
    while inst do
      visitor_lut[inst.inst_type](data, inst)
      inst = inst.next
    end
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
  local function add_new_inst(data, position, op, args)
    add_inst(data, new_inst(data, position, op, args))
  end

  ---@param data ILCompilerData
  ---@param inst ILCompiledInstruction
  ---@param position Position
  ---@param op Opcode
  ---@param args InstructionArguments
  local function insert_new_inst(data, inst, position, op, args)
    insert_inst(data, inst, new_inst(data, position, op, args))
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
      util.debug_abort("-- TODO: handle register shifting")
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

    local function determine_temporary(reg)
      if reg.temporary == nil then
        if reg.total_get_count == 0 or reg.total_set_count == 0 then
          util.debug_abort("Ill formed register with get or set counts == 0.")
        end
        reg.temporary = reg.total_get_count == 1 and reg.total_set_count == 1
      end
    end

    local function fill_regs_using_regs_list(list)
      for _, reg in ipairs(list) do
        -- determine_temporary(reg)
        -- if not reg.temporary then
          reg.temp_sort_index = #regs + 1
          regs[reg.temp_sort_index] = reg
        -- end
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
      for i = reg_count, 1, -1 do
        regs[i].current_reg = create_compiled_reg(data, data.local_reg_count + i - 1, regs[i].name)
        regs[i].temp_sort_index = nil
        regs[i] = nil
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
    -- TODO: what does this mean: [...]
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
    ["set_table"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
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
        util.debug_abort("-- TODO: logical binops")
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
    ["label"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
    end,
    ["jump"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
    end,
    ["test"] = function(data, inst)
      util.debug_abort("-- TODO: not implemented")
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

---@param func ILFunction
local function compile(func)
  local data = {func = func} ---@type ILCompilerData
  make_bytecode_func(data)
  determine_reg_usage(data)

  data.local_reg_count = 0
  data.compiled_instructions = ill.new(true)
  data.compiled_registers = {}
  data.constant_lut = {}
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
