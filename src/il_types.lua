
local util = require("util")
local il = require("il_util")
local number_ranges = require("number_ranges")
local error_code_util = require("error_code_util")

local function set_type(state, reg, reg_type)
  state.reg_types[reg] = reg_type
end

local function get_type(state, reg)
  return state.reg_types[reg]
end

local function new_empty_table()
  return il.new_type{
    type_flags = il.table_flag,
    table_classes = {
      {
        kvps = {},
        metatable = nil,
      },
    },
  }
end

local function make_type_from_ptr(state, ptr)
  return (({
    ["reg"] = function()
      if ptr.is_vararg then
        util.debug_abort("-- TODO: I hate vararg.")
      else
        return il.copy_type(get_type(state, ptr))
      end
    end,
    ["number"] = function()
      if ptr.value ~= ptr.value then
        util.debug_abort("-- TODO: Support NaN as number types.")
      end
      return il.new_type{
        type_flags = il.number_flag,
        number_ranges = {
          -- TODO: -inf and inf support
          number_ranges.inclusive(-1/0),
          number_ranges.inclusive(ptr.value, number_ranges.range_type.everything),
          number_ranges.exclusive(ptr.value),
        },
      }
    end,
    ["string"] = function()
      return il.new_type{
        type_flags = il.string_flag,
        string_ranges = {number_ranges.inclusive(-1/0)},
        string_values = {ptr.value},
      }
    end,
    ["boolean"] = function()
      return il.new_type{
        type_flags = il.boolean_flag,
        boolean_value = ptr.value,
      }
    end,
    ["nil"] = function()
      return il.new_type{type_flags = il.nil_flag}
    end,
  })[ptr.ptr_type] or function()
    util.debug_abort("Unknown IL ptr_type '"..ptr.ptr_type.."'.")
  end)()
end

-- TODO: use il_util functions for all type operations which should also reduce the amount of "inferred any"s
local modify_post_state_func_lut = {
  ["move"] = function(data, inst)
    set_type(inst.post_state, inst.result_reg, make_type_from_ptr(inst.pre_state, inst.right_ptr))
  end,
  ["get_upval"] = function(data, inst)
    set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.every_flag})
  end,
  ["set_upval"] = function(data, inst)
  end,
  ["get_table"] = function(data, inst)
    local base_type = get_type(inst.pre_state, inst.table_reg)
    local result_type, err = il.type_indexing(base_type, make_type_from_ptr(inst.pre_state, inst.key_ptr))
    if err then
      util.debug_print(error_code_util.get_message(err))
    end
    set_type(inst.post_state, inst.result_reg, result_type)
  end,
  ["set_table"] = function(data, inst) -- TODO: redo using new type system
    local table_type = util.debug_assert(get_type(inst.pre_state, inst.table_reg),
      "trying to get a field from a register that wasn't even alive?!"
    )
    if table_type.inst_type == "class" then -- TODO: better check for classes - see unions for example
      -- TODO: validate that the key used is actually valid for this class
    end
  end,
  ["set_list"] = function(data, inst)
    -- TODO: impl set_list
  end,
  ["new_table"] = function(data, inst)
    -- TODO: this would end up completely disallowing any gets/sets with this table because it's empty
    set_type(inst.post_state, inst.result_reg, new_empty_table())
  end,
  ["concat"] = function(data, inst)
    -- TODO: impl concat
    set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.string_flag})
  end,
  ["binop"] = function(data, inst)
    -- if il.is_logical_binop(inst) then
    --   -- TODO: check if the result value can be determined at this point already
    --   set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.boolean_flag})
    -- else
      -- TODO: this can be improved by a lot now
      set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.every_flag})
    -- end
  end,
  ["unop"] = function(data, inst)
    if inst.op == "not" then
      -- TODO: check if the result value can be determined at this point already
      set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.boolean_flag})
    else
      -- TODO: this can be improved by a lot now
      set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.every_flag})
    end
  end,
  ["label"] = function(data, inst)
  end,
  ["jump"] = function(data, inst)
  end,
  ["test"] = function(data, inst)
  end,
  ["call"] = function(data, inst)
    for _, reg in ipairs(inst.result_regs) do
      set_type(inst.post_state, reg, il.new_type{type_flags = il.every_flag})
    end
  end,
  ["ret"] = function(data, inst)
  end,
  ["closure"] = function(data, inst)
    -- util.debug_abort("-- TODO: func type with identity")
    set_type(inst.post_state, inst.result_reg, il.new_type{type_flags = il.function_flag})
  end,
  ["vararg"] = function(data, inst)
  end,
  ["scoping"] = function(data, inst)
  end,
}

local function new_state()
  return {
    reg_types = {},
  }
end

local function walk_block(data, block)
  local inst = block.start_inst
  local prev_inst
  repeat
    local pre_state
    if prev_inst then
      pre_state = prev_inst.post_state
      inst.pre_state = pre_state
    else -- first iteration
      if block.is_main_entry_block then
        pre_state = new_state()
        inst.pre_state = pre_state
        for i = 1, #data.func.param_regs do
          local param_reg = data.func.param_regs[i]
          local live_reg = inst.live_regs[i]
          util.debug_assert(param_reg == live_reg,
            "Something weird must have happened with the order for param regs."
          )
          set_type(pre_state, param_reg, il.new_type{type_flags = il.every_flag})
        end
      else
        util.debug_abort("-- TODO: figure out pre_state based on all non loop source_links.")
      end
    end

    local post_state = new_state()
    inst.post_state = post_state
    modify_post_state_func_lut[inst.inst_type](data, inst)
    -- carry over all reg types from pre_state if they don't have a new type and aren't out of scope
    for reg, reg_type in pairs(pre_state.reg_types) do
      if not get_type(post_state, reg) and not (inst.regs_stop_at_lut and inst.regs_stop_at_lut[reg]) then
        set_type(post_state, reg, il.copy_type(reg_type))
      end
    end
    prev_inst = inst
    inst = inst.next
  until inst == block.stop_inst.next
end

---@param func ILFunction
local function resolve_types(func)
  local data = {func = func}
  if not func.has_start_stop_insts then
    il.eval_live_regs(data)
  end
  walk_block(data, func.blocks.first)
  func.has_types = true
end

return resolve_types
