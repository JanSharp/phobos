
local linq = require("linq")

---@param reg ILRegister
local function get_reg(reg, context)
  if context.reg_label_lut[reg] then
    return context.reg_label_lut[reg]
  end
  local id = context.next_reg_id
  context.next_reg_id = id + 1
  local function make_label(prefix, name)
    local label = prefix.."("..id
      -- FIXME: remove this, or make it prettier, once register indexes are implemented fully
      ..(reg.index_in_linked_groups and (" <"..reg.index_in_linked_groups..">") or "")
      ..(reg.requires_move_into_register_group and " <move>" or "")
      ..(reg.predetermined_reg_index and (" >>"..reg.predetermined_reg_index.."<<") or "")
      ..(name and ("|"..name) or "")
      ..")"
    context.reg_label_lut[reg] = label
    return label
  end
  if reg.is_vararg then
    return make_label("VAR")
  else
    return make_label("R", reg.name)
  end
end

local const_ptr_getter_lut = {
  ["number"] = function(ptr, context)
    return tostring(ptr.value)
  end,
  ["string"] = function(ptr, context)
    return string.format("%q", ptr.value):gsub("\\\n", "\\n")
  end,
  ["boolean"] = function(ptr, context)
    return tostring(ptr.value)
  end,
  ["nil"] = function(ptr, context)
    return "nil"
  end,
}

local function get_ptr(ptr, context)
  return (const_ptr_getter_lut[ptr.ptr_type] or get_reg)(ptr, context)
end

local function get_upval(upval, context)
  if context.upval_label_lut[upval] then
    return context.upval_label_lut[upval]
  end
  local id = context.next_upval_id
  context.next_upval_id = id + 1
  local label = "UP("..id..(upval.name and ("|"..upval.name) or "")..")"
  context.upval_label_lut[upval] = label
  return label
end

local function get_label_label(label, context)
  if context.label_label_lut[label] then
    return context.label_label_lut[label]
  end
  local id = context.next_label_id
  context.next_label_id = id + 1
  local label_label = "::"..id..(label.name and ("|"..label.name) or "").."::"
  context.label_label_lut[label] = label_label
  return label_label
end

local function get_list(getter, list, context, separator)
  local out = {}
  for i, ptr in ipairs(list) do
    out[i] = getter(ptr, context)
  end
  return table.concat(out, separator or ", ")
end

local instruction_label_getter_lut = {
  ["move"] = function(inst, context)
    return "MOVE", get_reg(inst.result_reg, context).." := "..get_ptr(inst.right_ptr, context)
  end,
  ["get_upval"] = function(inst, context)
    return "GETUPVAL", get_reg(inst.result_reg, context).." := "..get_upval(inst.upval, context)
  end,
  ["set_upval"] = function(inst, context)
    return "SETUPVAL", get_upval(inst.upval, context).." := "..get_ptr(inst.right_ptr, context)
  end,
  ["get_table"] = function(inst, context)
    return "GETTABLE", get_reg(inst.result_reg, context).." := "..get_reg(inst.table_reg, context).."["..get_ptr(inst.key_ptr, context).."]"
  end,
  ["set_table"] = function(inst, context)
    return "SETTABLE", get_reg(inst.table_reg, context).."["..get_ptr(inst.key_ptr, context).."] := "..get_ptr(inst.right_ptr, context)
  end,
  ["set_list"] = function(inst, context)
    return "SETLIST", get_reg(inst.table_reg, context).."["..inst.start_index..", ..."..(inst.right_ptrs[#inst.right_ptrs].is_vararg and "" or (", "..(inst.start_index + #inst.right_ptrs - 1))).."] := "..get_list(get_ptr, inst.right_ptrs, context)
  end,
  ["new_table"] = function(inst, context)
    return "NEWTABLE", get_reg(inst.result_reg, context).." := {} size("..inst.array_size..", "..inst.hash_size..")"
  end,
  ["concat"] = function(inst, context)
    return "CONCAT", get_reg(inst.result_reg, context).." := "..get_list(get_ptr, inst.right_ptrs, context, "..")
  end,
  ["binop"] = function(inst, context)
    return "BINOP", get_reg(inst.result_reg, context).." := "..get_ptr(inst.left_ptr, context).." "..inst.op.." "..get_ptr(inst.right_ptr, context)
  end,
  ["unop"] = function(inst, context)
    return "UNOP", get_reg(inst.result_reg, context).." := "..inst.op.." "..get_ptr(inst.right_ptr, context)
  end,
  ["label"] = function(inst, context)
    return "LABEL", get_label_label(inst, context)
  end,
  ["jump"] = function(inst, context)
    return "JUMP", "-> "..get_label_label(inst.label, context)
  end,
  ["test"] = function(inst, context)
    return "TEST", "if "..(inst.jump_if_true and "" or "not ")..get_ptr(inst.condition_ptr, context).." then -> "..get_label_label(inst.label, context)
  end,
  ["call"] = function(inst, context)
    return "CALL", (inst.result_regs[1] and (get_list(get_reg, inst.result_regs, context).." := ") or "")..get_reg(inst.func_reg, context).."("..get_list(get_ptr, inst.arg_ptrs, context)..")"
  end,
  ["ret"] = function(inst, context)
    return "RETURN", "return"..(inst.ptrs[1] and (" "..get_list(get_ptr, inst.ptrs, context)) or "")
  end,
  ["closure"] = function(inst, context)
    return "CLOSURE", get_reg(inst.result_reg, context).." := <some function>" -- TODO: what is there to say about a function?
  end,
  ["vararg"] = function(inst, context)
    return "VARARG", get_list(get_reg, inst.result_regs, context).." := vararg"
  end,
  ["close_up"] = function(inst, context)
    return "CLOSEUP", "close upvalues for regs: "..get_list(get_reg, inst.regs, context)
  end,
  ["scoping"] = function(inst, context)
    return "SCOPING", "alive: "..get_list(get_reg, inst.regs, context)
  end,
  ["to_number"] = function(inst, context)
    return "TONUMBER", get_reg(inst.result_reg, context).." := tonumber("..get_ptr(inst.right_ptr, context)..")"
  end,
}

---@param instruction ILInstruction
local function get_label(instruction, context)
  local main_label, description = (
    instruction_label_getter_lut[instruction.inst_type]
    or function(_, _)
      return "UNKNOWN"
    end--[[@as fun(inst, context):string]]
  )(instruction, context)
  local real_live_regs = ""
  if instruction.next_border and instruction.next_border.real_live_regs then
    real_live_regs = "["
      ..table.concat(
        linq(instruction.next_border.real_live_regs)
          :select(function(reg_range) return get_reg(reg_range.reg, context)
            ..(reg_range.color and ("c"..reg_range.color) or "") end)
          :to_array(),
        ", "
      )
      .."]"
  end
  return main_label, description, real_live_regs
end

local function new_context()
  return {
    reg_label_lut = {},
    next_reg_id = 1,
    upval_label_lut = {},
    next_upval_id = 1,
    label_label_lut = {},
    next_label_id = 1,
  }
end

return function(func, format_callback)
  local out = {}
  local context = new_context()
  local data = {}
  local inst = func.instructions.first
  local pc = 1
  while inst do
    local label, description, real_live_regs = get_label(inst, context)
    data.pc = pc
    data.label = label
    data.group_label = inst.inst_group and inst.inst_group.group_type:upper() or ""
    data.index = inst.index
    data.description = description
    data.real_live_regs = real_live_regs
    data.inst = inst
    local line = format_callback(data)
    if line then
      out[#out+1] = line
      out[#out+1] = "\n"
    end
    pc = pc + 1
    inst = inst.next
  end
  return table.concat(out)
end
