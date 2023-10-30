
local il = require("il_util")

---@param func ILFunction
---@param inst ILInstruction
---@param ptrs ILPointer[]
---@param set_at_in_ptrs_func fun(func: ILFunction, inst: ILInstruction, ptr: ILPointer, index: integer?)
local function expand_ptr_list(func, inst, ptrs, set_at_in_ptrs_func)
  for i, ptr in ipairs(ptrs) do
    if ptr.ptr_type ~= "reg" then
      local temp_reg = il.new_reg()
      il.insert_before_inst(func, inst, il.new_move{
        position = inst.position,
        right_ptr = ptr,
        result_reg = temp_reg,
      })
      set_at_in_ptrs_func(func, inst, temp_reg, i)
    end
  end
end

---@type table<string, fun(func: ILFunction, inst: ILInstruction)>
local inst_expand_ptrs_lut = {
  ---@param inst ILSetList
  ["set_list"] = function(func, inst)
    expand_ptr_list(func, inst, inst.right_ptrs, il.set_at_in_right_ptrs)
  end,
  ---@param inst ILConcat
  ["concat"] = function(func, inst)
    expand_ptr_list(func, inst, inst.right_ptrs, il.set_at_in_right_ptrs)
  end,
  ---@param inst ILCall
  ["call"] = function(func, inst)
    expand_ptr_list(func, inst, inst.arg_ptrs, il.set_at_in_arg_ptrs)
  end,
  ---@param inst ILRet
  ["ret"] = function(func, inst)
    if inst.ptrs[1] then
      expand_ptr_list(func, inst, inst.ptrs, il.set_at_in_ptrs)
    end
  end,
}

---@param func ILFunction
local function expand_ptrs(func)
  local inst = func.instructions.first
  while inst do
    local inst_expand_ptrs = inst_expand_ptrs_lut[inst.inst_type]
    if inst_expand_ptrs then
      inst_expand_ptrs(func, inst)
    end
    inst = inst.next
  end
end

---@param func ILFunction
local function expand_ptrs_recursive(func)
  expand_ptrs(func)
  for _, inner_func in ipairs(func.inner_functions) do
    expand_ptrs_recursive(inner_func)
  end
end

return {
  expand_ptrs = expand_ptrs,
  expand_ptrs_recursive = expand_ptrs_recursive,
}
