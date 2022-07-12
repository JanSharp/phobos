
local phobos_consts = require("constants")
local util = require("util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes

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
  ["concat"] = function(data, inst)
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
  determine_reg_usage(data)
  -- generate(data)
  return data.result
end

return compile
