
local function get_reg(reg, context)
  if context.reg_label_lut[reg] then
    return context.reg_label_lut[reg]
  end
  local id = context.next_reg_id
  context.next_reg_id = id + 1
  local function make_label(prefix, name)
    local label = prefix.."("..id..(name and ("|"..name) or "")..")"
    context.reg_label_lut[reg] = label
    return label
  end
  if reg.ptr_type == "reg" then
    return make_label("R", reg.name)
  elseif reg.ptr_type == "vararg" then
    return make_label("VAR")
  else
    error(reg.ptr_type and ("unknown ptr_type '"..reg.ptr_type.."'") or "invalid nil ptr_type")
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

local function get_list(getter, list, context)
  local out = {}
  for i, ptr in ipairs(list) do
    out[i] = getter(ptr, context)
  end
  return table.concat(out, ", ")
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
    return "SETTABLE", get_reg(inst.table_reg, context).."["..get_ptr(inst.key_ptr, context).."]".." := "..get_ptr(inst.right_ptr, context)
  end,
  ["new_table"] = function(inst, context)
    return "NEWTABLE", get_reg(inst.result_reg, context).." := {} size("..inst.array_size..", "..inst.hash_size..")"
  end,
  ["binop"] = function(inst, context)
    return "BINOP", get_reg(inst.result_reg, context).." := "..get_ptr(inst.left_ptr, context).." "..inst.op.." "..get_ptr(inst.right_ptr, context)
  end,
  ["unop"] = function(inst, context)
    return "BINOP", get_reg(inst.result_reg, context).." := "..inst.op.." "..get_ptr(inst.right_ptr, context)
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
  ["scoping"] = function(inst, context)
    return "SCOPING", get_list(get_reg, inst.result_regs, context).." := vararg"
  end,
}

local function get_label(instruction, context)
  return (
    instruction_label_getter_lut[instruction.inst_type]
    or function()
      return "UNKNOWN"
    end
  )(instruction, context)
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
  for pc, inst in ipairs(func.instructions) do
    local label, description = get_label(inst, context)
    local line = format_callback(pc, label..string.rep(" ", 8 - #label), description, inst)
    if line then
      out[#out+1] = line
      out[#out+1] = "\n"
    end
  end
  return table.concat(out)
end
