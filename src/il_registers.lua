
local util = require("util")
local ll = require("linked_list")
local il_borders = require("il_borders")

-- utility

local visit_regs_for_inst
local visit_all_regs
local inst_uses_reg
local get_flag = 1
local set_flag = 2
local get_and_set_flags = 3
do
  local get = get_flag
  local set = set_flag
  local get_and_set = get_and_set_flags

  local visit_reg

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
      visit_ptr(data, inst, inst.key_ptr, get)
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
      visit_reg(data, inst, inst.result_reg, set)
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
    ---@param inst ILClosure
    ["closure"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set) -- has to be at the top of the stack
      for _, upval in ipairs(inst.func.upvals) do
        if upval.parent_type == "local" then
          visit_reg(data, inst, upval.reg_in_parent_func, get)
        end
      end
    end,
    ["vararg"] = function(data, inst)
      visit_reg_list(data, inst, inst.result_regs, set) -- must be in order
    end,
    ["close_up"] = function(data, inst)
      -- this neither gets or sets those registers, but I guess get is more accurate. Not sure to be honest
      visit_reg_list(data, inst, inst.regs, get)
    end,
    ["scoping"] = function(data, inst)
      visit_reg_list(data, inst, inst.regs, get_and_set)
    end,
    ["to_number"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg, set)
      visit_reg(data, inst, inst.right_ptr, get)
    end,
  }

  -- ---@param visit_ptr fun(data: T, inst: ILInstruction, ptr: ILPointer, get_set: 1|2|3)

  ---@generic T
  ---@param data T @ A state object passed as is to the visit callback. Can be `nil`.
  ---@param inst ILInstruction
  ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
  function visit_regs_for_inst(data, inst, visit_reg_func)
    visit_reg = visit_reg_func
    visitor_lut[inst.inst_type](data, inst)
  end

  ---@generic T
  ---@param data T @ A state object passed as is to the visit callback. Can be `nil`.
  ---@param func ILFunction
  ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
  function visit_all_regs(data, func, visit_reg_func)
    visit_reg = visit_reg_func
    local inst = func.instructions.first
    while inst do
      visitor_lut[inst.inst_type](data, inst)
      inst = inst.next
    end
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  ---@return boolean
  function inst_uses_reg(inst, reg)
    local result = false
    visit_reg = function(_, _, current_reg)
      if current_reg == reg then
        result = true
      end
    end
    visitor_lut[inst.inst_type](nil, inst)
    return result
  end
end

-- creating

---NOTE: If you're worried about parameter regs not getting handled in here, don't be! They are handled thanks
-- to the entry scoping instruction and ending scoping instruction that are managed by other utility functions

local eval_start_stop_for_all_regs
do
  ---@param data {func: ILFunction, regs_lut: table<ILRegister, true>}
  ---@param inst ILInstruction
  ---@param reg ILRegister
  local function visit_reg(data, inst, reg)
    if not reg.start_at then
      reg.start_at = inst
      if not data.regs_lut[reg] then
        data.regs_lut[reg] = true
        ll.append(data.func.all_regs, reg)
      end
    end
    reg.stop_at = inst
  end

  ---@param func ILFunction
  function eval_start_stop_for_all_regs(func)
    func.all_regs = ll.new_list("reg_in_func")
    local data = {func = func, regs_lut = {}}
    local inst = func.instructions.first
    while inst do
      visit_regs_for_inst(data, inst, visit_reg)
      inst = inst.next
    end
  end
end

---IMPORTANT: Keep the list of IL instructions without any registers up to date
local insts_without_regs_lut = util.invert{"jump", "label"}

---@param func ILFunction
local function eval_start_stop_luts_and_lists(func)
  local shared_empty = setmetatable({}, {
    __newindex = function(_, k)
      util.debug_abort("Attempt to write to a start/stop list/lut for an instruction that has no registers. \z
        (Key: '"..tostring(k).."')"
      )
    end,
  })
  local inst = func.instructions.first
  while inst do
    if insts_without_regs_lut[inst.inst_type] then
      inst.regs_start_at_list = shared_empty
      inst.regs_start_at_lut = shared_empty
      inst.regs_stop_at_list = shared_empty
      inst.regs_stop_at_lut = shared_empty
    else
      inst.regs_start_at_list = {}
      inst.regs_start_at_lut = {}
      inst.regs_stop_at_list = {}
      inst.regs_stop_at_lut = {}
    end
    inst = inst.next
  end

  local function add_to_list_and_lut(list, lut, reg)
    if lut[reg] then return end
    lut[reg] = true
    list[#list+1] = reg
  end

  for reg in ll.iterate(func.all_regs)--[[@as fun(): ILRegister?]] do
    add_to_list_and_lut(reg.start_at.regs_start_at_list, reg.start_at.regs_start_at_lut, reg)
    add_to_list_and_lut(reg.stop_at.regs_stop_at_list, reg.stop_at.regs_stop_at_lut, reg)
  end
end

---@param func ILFunction
local function eval_live_regs(func)
  local live_regs = {}
  for border in il_borders.iterate_borders(func) do
    -- stopping at prev_inst, remove them from live_regs for this border
    local lut = border.prev_inst and border.prev_inst.regs_stop_at_lut
    if lut then
      local j = 1
      for i = 1, #live_regs do
        local reg = live_regs[i]
        live_regs[i] = nil
        if not lut[reg] then -- if it's not stopping it's still alive
          live_regs[j] = reg
          j = j + 1
        end
      end
    end

    border.live_regs = util.shallow_copy(live_regs)

    -- starting at next_inst, add them to live_regs for the next border
    local list = border.next_inst and border.next_inst.regs_start_at_lut
    if list then
      for _, reg in ipairs(list) do
        live_regs[#live_regs+1] = reg
      end
    end
  end
end

---@param func ILFunction
local function create_reg_liveliness(func)
  util.debug_assert(not func.has_reg_liveliness, "The create_reg_liveliness function is meant to be run \z
    for the initial creation of reg liveliness, however the given function already has reg liveliness."
  )
  func.has_reg_liveliness = true

  il_borders.ensure_has_borders(func)
  eval_start_stop_for_all_regs(func)
  eval_start_stop_luts_and_lists(func)
  eval_live_regs(func)
end

---@param func ILFunction
local function create_reg_liveliness_recursive(func)
  create_reg_liveliness(func)
  for _, inner_func in ipairs(func.inner_functions) do
    create_reg_liveliness_recursive(inner_func)
  end
end

---@param func ILFunction
local function ensure_has_reg_liveliness(func)
  if func.has_reg_liveliness then return end
  create_reg_liveliness(func)
end

---@param func ILFunction
local function ensure_has_reg_liveliness_recursive(func)
  ensure_has_reg_liveliness(func)
  for _, inner_func in ipairs(func.inner_functions) do
    ensure_has_reg_liveliness_recursive(inner_func)
  end
end

-- modifying

-- inserting

-- removing


-- temp copy paste:
--[=[

---@param inst ILInstruction
---@param reg ILRegister
local function get_get_set_flags_for_reg_for_inst_group(inst, reg)
  local total_get_set = 0
  local function callback(_, _, current_reg, get_set)
    if current_reg == reg then
      total_get_set = bit32.bor(total_get_set, get_set)
    end
  end
  if inst.inst_group then
    local current_inst = inst.inst_group.start
    repeat
      il.visit_regs_for_inst(nil, inst, callback)
    until current_inst == inst.inst_group.stop
  else
    il.visit_regs_for_inst(nil, inst, callback)
  end
  return total_get_set
end

---@param inst ILInstruction
---@param reg ILRegister
local function inst_group_gets_reg(inst, reg)
  return bit32.band(il.get_flag, get_get_set_flags_for_reg_for_inst_group(inst, reg)) ~= 0
end

---@param inst ILInstruction
---@param reg ILRegister
local function inst_group_sets_reg(inst, reg)
  return bit32.band(il.set_flag, get_get_set_flags_for_reg_for_inst_group(inst, reg)) ~= 0
end

]=]

return {
  create_reg_liveliness = create_reg_liveliness,
  create_reg_liveliness_recursive = create_reg_liveliness_recursive,
  ensure_has_reg_liveliness = ensure_has_reg_liveliness,
  ensure_has_reg_liveliness_recursive = ensure_has_reg_liveliness_recursive,
}
