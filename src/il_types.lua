
local util = require("util")
local il = require("il_util")

local function set_type(state, reg, reg_type)
  state.reg_types[reg] = reg_type
end

local function get_type(state, reg)
  return state.reg_types[reg]
end

-- TODO: use il_util functions for all type operations which should also reduce the amount of "inferred any"s
local modify_post_state_func_lut = {
  ["move"] = function(data, inst)
    set_type(inst.post_state, inst.result_reg, il.make_type_from_ptr(inst.pre_state, inst.right_ptr))
  end,
  ["get_upval"] = function(data, inst)
    set_type(inst.post_state, inst.result_reg, il.new_any{inferred = true})
  end,
  ["set_upval"] = function(data, inst)
  end,
  ["get_table"] = function(data, inst)
    local table_type = util.debug_assert(get_type(inst.pre_state, inst.table_reg),
      "trying to get a field from a register that wasn't even alive?!"
    )
    -- if not table_type or table_type == "unknown" then
    --   set_type(inst.pre_state, inst.table_reg, il.new_table{})
    -- elseif not il.contains_type(table_type, il.new_table{}) then
    --   -- TODO : make this a proper warning somehow
    --   print("Expected to index into type 'table', got '"..table_type.type_id.."' at "
    --     ..util.pos_str(inst.position)
    --   )
    -- end
    if table_type.inst_type == "class" then -- TODO: better check for classes - see unions for example
      -- TODO: validate that the key used is actually valid for this class
      -- TODO: search for key type in the kvps and evaluate a resulting type
      set_type(inst.post_state, inst.result_reg, il.new_any{inferred = true})
    else
      set_type(inst.post_state, inst.result_reg, il.new_any{inferred = true})
    end
  end,
  ["set_table"] = function(data, inst)
    local table_type = util.debug_assert(get_type(inst.pre_state, inst.table_reg),
      "trying to get a field from a register that wasn't even alive?!"
    )
    if table_type.inst_type == "class" then -- TODO: better check for classes - see unions for example
      -- TODO: validate that the key used is actually valid for this class
    end
  end,
  ["new_table"] = function(data, inst)
    -- TODO: this would end up completely disallowing any gets/sets with this table because it's empty
    set_type(inst.post_state, inst.result_reg, il.new_class{is_table = true})
  end,
  ["binop"] = function(data, inst)
    if il.is_logical_binop(inst) then
      set_type(inst.post_state, inst.result_reg, il.new_boolean{})
    else
      set_type(inst.post_state, inst.result_reg, il.new_any{inferred = true})
    end
  end,
  ["unop"] = function(data, inst)
    if inst.op == "not" then
      set_type(inst.post_state, inst.result_reg, il.new_boolean{})
    else
      set_type(inst.post_state, inst.result_reg, il.new_any{inferred = true})
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
      set_type(inst.post_state, reg, il.new_any{inferred = true})
    end
  end,
  ["ret"] = function(data, inst)
  end,
  ["closure"] = function(data, inst)
    set_type(inst.post_state, inst.result_reg, il.new_literal_function{func = inst.func})
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
  local inst_node = block.instructions.first
  local inst
  while inst_node do
    local pre_state
    if inst then -- inst is still prev inst
      pre_state = inst.post_state
      inst = inst_node.value
      inst.pre_state = pre_state
    else -- first iteration
      inst = inst_node.value
      if block.is_main_entry_block then
        pre_state = new_state()
        inst.pre_state = pre_state
        for i = 1, #data.func.param_regs do
          local param_reg = data.func.param_regs[i]
          local live_reg = inst.live_regs[i]
          util.debug_assert(param_reg == live_reg,
            "Something weird must have happened with the order for param regs."
          )
          pre_state.reg_types[param_reg] = il.new_any{inferred = true}
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
      if not post_state.reg_types[reg] and not (inst.regs_stop_at_lut and inst.regs_stop_at_lut[reg]) then
        post_state.reg_types[reg] = util.copy(reg_type)
      end
    end
    inst_node = inst_node.next
  end
end

local function resolve_types(func)
  local data = {func = func}
  walk_block(data, func.blocks.first)
end

return resolve_types
