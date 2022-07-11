
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes

local step_one
do
  local function visit_reg(data, inst, reg)
    if not reg.start_at then
      reg.start_at = inst
      data.all_regs[#data.all_regs+1] = reg
    end
    reg.stop_at = inst
  end

  local function visit_reg_list(data, inst, regs)
    for _, reg in ipairs(regs) do
      visit_reg(data, inst, reg)
    end
  end

  local function visit_ptr(data, inst, ptr)
    if ptr.ptr_type == "reg" then
      visit_reg(data, inst, ptr)
    end
  end

  local function visit_ptr_list(data, inst, ptrs)
    for _, ptr in ipairs(ptrs) do
      visit_ptr(data, inst, ptr)
    end
  end

  local reg_liveliness_lut = {
    ["move"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["get_upval"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
    end,
    ["set_upval"] = function(data, inst)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["get_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_reg(data, inst, inst.table_reg)
    end,
    ["set_table"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg)
      visit_ptr(data, inst, inst.key_ptr)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["set_list"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg)
      visit_ptr_list(data, inst, inst.right_ptrs) -- must be in order
    end,
    ["new_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg) -- has to be at the top of the stack
    end,
    ["binop"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg) -- has to be at the top of the stack if this is a concat
      visit_ptr(data, inst, inst.left_ptr)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["unop"] = function(data, inst)
      visit_ptr(data, inst, inst.result_reg)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["label"] = function(data, inst)
    end,
    ["jump"] = function(data, inst)
    end,
    ["test"] = function(data, inst)
      visit_ptr(data, inst, inst.condition_ptr)
    end,
    ["call"] = function(data, inst)
      visit_reg(data, inst, inst.func_reg)
      visit_ptr_list(data, inst, inst.arg_ptrs) -- must be in order right above func_reg
      visit_reg_list(data, inst, inst.result_regs) -- must be in order right above func_reg
    end,
    ["ret"] = function(data, inst)
      visit_ptr_list(data, inst, inst.ptrs) -- must be in order
    end,
    ["closure"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg) -- has to be at the top of the stack
    end,
    ["vararg"] = function(data, inst)
      visit_reg_list(data, inst, inst.result_regs) -- must be in order
    end,
    ["scoping"] = function(data, inst)
      visit_reg_list(data, inst, inst.regs)
    end,
  }

  function step_one(data)
    data.all_regs = {}
    do
      local inst = data.func.instructions.first
      while inst do
        reg_liveliness_lut[inst.inst_type](data, inst)
        inst = inst.next
      end
    end
    -- TODO: ok, now what
  end
end


local function add_stat(data, position_inst, op, args)
  local position = position_inst.position
  args.line = position and position.line
  args.column = position and position.column
  args.op = op
  data.result.instructions[#data.result.instructions+1] = args
end

local generate_inst_lut = {
  ["move"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["get_upval"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["set_upval"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["get_table"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["set_table"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["set_list"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["new_table"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["binop"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["unop"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
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
      add_stat(data, inst, opcodes["return"], {a = 0, b = 1})
    end
  end,
  ["closure"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["vararg"] = function(data, inst)
    util.debug_abort("-- TODO: not implemented")
  end,
  ["scoping"] = function(data, inst)
    -- no op
  end,
}

local function generate(data)
  local inst = data.func.instructions.first
  while inst do
    generate_inst_lut[inst.inst_type](data, inst)
    inst = inst.next
  end
end

local function make_bytecode_func(data)
  local func = data.func
  local result = {
    num_params = #func.param_regs,
    is_vararg = func.is_vararg,
    max_stack_size = 0, -- TODO: set me
    instructions = {},
    constants = {},
    inner_functions = {},
    upvals = {},
    source = func.source,
    debug_registers = {},
  }
  data.result = result
  for i, upval in ipairs(func.upvals) do
    if upval.parent_type == "local" then
      util.debug_abort("-- TODO: not implemented")
    elseif upval.parent_type == "upval" then
      util.debug_abort("-- TODO: not implemented")
    elseif upval.parent_type == "env" then
      result.upvals[i] = {
        index = 0,
        name = "_ENV",
        in_stack = true,
        local_idx = 0,
      }
    end
  end
end

---@param func ILFunction
local function compile(func)
  local data = {func = func}
  make_bytecode_func(data)
  -- step_one(data)
  generate(data)
  return data.result
end

return compile
