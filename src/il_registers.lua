
local util = require("util")
local ll = require("linked_list")
local ill = require("indexed_linked_list")
local il_borders = require("il_borders")

----====----====----====----====----====----====----====----====----====----====----====----====----
-- utility
----====----====----====----====----====----====----====----====----====----====----====----====----

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

---@param list ILRegister[]
---@param lut table<ILRegister, boolean>
---@param reg ILRegister
local function add_to_list_and_lut(list, lut, reg)
  if lut[reg] then return end
  lut[reg] = true
  list[#list+1] = reg
end

---@param list ILRegister[]
---@param lut table<ILRegister, boolean>
---@param reg ILRegister
local function remove_from_list_and_lut(list, lut, reg)
  util.debug_assert(lut[reg], "When removing from a list and lut the given register must be contained in them.")
  lut[reg] = nil
  util.remove_from_array_fast(list, reg)
end

---@param func ILFunction
---@param func_name string
local function assert_has_reg_liveliness(func, func_name)
  util.debug_assert(
    func.has_reg_liveliness,
    "Attempt to use 'il_registers."..func_name.."' with a func without reg liveliness."
  )
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- creating
----====----====----====----====----====----====----====----====----====----====----====----====----

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

----====----====----====----====----====----====----====----====----====----====----====----====----
-- modifying
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param reg ILRegister
---@param start_at ILInstruction
local function add_start_at(reg, start_at)
  reg.start_at = start_at
  add_to_list_and_lut(start_at.regs_start_at_list, start_at.regs_start_at_lut, reg)
end

---@param reg ILRegister
local function remove_start_at(reg)
  remove_from_list_and_lut(reg.start_at.regs_start_at_list, reg.start_at.regs_start_at_lut, reg)
  reg.start_at = nil
end

---@param reg ILRegister
---@param stop_at ILInstruction
local function add_stop_at(reg, stop_at)
  reg.stop_at = stop_at
  add_to_list_and_lut(stop_at.regs_start_at_list, stop_at.regs_start_at_lut, reg)
end

---@param reg ILRegister
local function remove_stop_at(reg)
  remove_from_list_and_lut(reg.stop_at.regs_stop_at_lut, reg.stop_at.regs_stop_at_lut, reg)
  reg.stop_at = nil
end

---@param func ILFunction
---@param from_inst ILInstruction
---@param to_inst ILInstruction
---@param reg ILRegister
local function add_to_live_regs_between_insts(func, from_inst, to_inst, reg)
  for border in il_borders.iterate_borders(func, from_inst.next_border, to_inst.prev_border) do
    border.live_regs[#border.live_regs+1] = reg
  end
end

---@param func ILFunction
---@param from_inst ILInstruction
---@param to_inst ILInstruction
---@param reg ILRegister
local function remove_from_live_regs_between_insts(func, from_inst, to_inst, reg)
  for border in il_borders.iterate_borders(func, from_inst.next_border, to_inst.prev_border) do
    util.remove_from_array_fast(border.live_regs, reg)
  end
end

---@param func ILFunction
---@param reg ILRegister
---@param start_at ILInstruction
local function set_reg_start_at(func, reg, start_at)
  local old_start_at = reg.start_at
  if old_start_at == start_at then return end

  if not old_start_at then
    add_start_at(reg, start_at)
    return
  end

  remove_start_at(reg)
  add_start_at(reg, start_at)
  if old_start_at.index < start_at.index then
    remove_from_live_regs_between_insts(func, old_start_at, start_at, reg)
  else -- old is greater
    add_to_live_regs_between_insts(func, start_at, old_start_at, reg)
  end
end

---@param func ILFunction
---@param reg ILRegister
---@param stop_at ILInstruction
local function set_reg_stop_at(func, reg, stop_at)
  local old_stop_at = reg.stop_at
  if old_stop_at == stop_at then return end

  if not old_stop_at then
    add_stop_at(reg, stop_at)
    return
  end

  remove_stop_at(reg)
  add_stop_at(reg, stop_at)
  if old_stop_at.index < stop_at.index then
    add_to_live_regs_between_insts(func, old_stop_at, stop_at, reg)
  else -- old is greater
    remove_from_live_regs_between_insts(func, stop_at, old_stop_at, reg)
  end
end

---Can be called before the register has actually been added to the instruction.
---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
local function add_reg_to_inst(func, inst, reg)
  if not func.has_reg_liveliness then return end

  if not reg.start_at then
    util.debug_assert(not reg.stop_at, "When a reg doesn't have start_at it must also not have stop_at. \z
      Such registers are most of the time newly created registers."
    )
    add_start_at(reg, inst)
    add_stop_at(reg, inst)
    ll.append(func.all_regs, reg)
    return
  end

  if inst.index < reg.start_at.index then
    set_reg_start_at(func, reg, inst)
  elseif reg.stop_at.index < inst.index then
    set_reg_stop_at(func, reg, inst)
  end
end

---@param func ILFunction
---@param inst ILInstruction
---@param ptr ILPointer
local function add_ptr_to_inst(func, inst, ptr)
  if ptr.ptr_type == "reg" then
    ---@cast ptr ILRegister
    add_reg_to_inst(func, inst, ptr)
  end
end

---@param inst_iter fun(): ILInstruction?
---@param reg ILRegister
---@return ILInstruction
local function find_inst_using_reg(inst_iter, reg)
  for inst in inst_iter do
    if inst_uses_reg(inst, reg) then
      return inst
    end
  end
  ---@diagnostic disable-next-line: missing-return
  util.debug_abort("Unable to find instruction using register when there must be at least 1.")
end

---Can be called before the register has actually been removed from the instruction.
---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
local function remove_reg_from_inst(func, inst, reg)
  if not func.has_reg_liveliness then return end

  local removed_start = inst == reg.start_at and not inst_uses_reg(inst, reg)
  local removed_stop = inst == reg.stop_at and not inst_uses_reg(inst, reg)

  if removed_start and removed_stop then
    remove_start_at(reg)
    remove_stop_at(reg)
    ll.remove(func.all_regs, reg)
    return
  end

  if removed_start then
    local new_start_at = find_inst_using_reg(ill.iterate(func.instructions, inst.next), reg)
    set_reg_start_at(func, reg, new_start_at)
    return
  end

  if removed_stop then
    local new_stop_at = find_inst_using_reg(ill.iterate_reverse(func.instructions, inst.prev), reg)
    set_reg_stop_at(func, reg, new_stop_at)
    return
  end
end

---@param func ILFunction
---@param inst ILInstruction
---@param ptr ILPointer
local function remove_ptr_from_inst(func, inst, ptr)
  if ptr.ptr_type == "reg" then
    ---@cast ptr ILRegister
    remove_reg_from_inst(func, inst, ptr)
  end
end

local allow_modifying_inst_groups = false

---@param allow boolean
local function set_allow_modifying_inst_groups(allow)
  allow_modifying_inst_groups = allow
end

---@param inst ILInstruction
local function assert_is_not_inst_group(inst)
  if allow_modifying_inst_groups then return end
  util.debug_assert(not inst.inst_group, "Attempt to modify registers or pointers of an instruction which \z
    is part of an instruction group. Use the dedicated functions for modifying instruction groups instead."
  )
end

----------------------------------------------------------------------------------------------------
-- changing registers or pointers on instructions
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILMove|ILGetUpval|ILGetTable|ILNewTable|ILConcat|ILBinop|ILUnop|ILClosure|ILToNumber
---@param reg ILRegister
local function set_result_reg(func, inst, reg)
  assert_is_not_inst_group(inst)
  if reg == inst.result_reg then return end
  remove_reg_from_inst(func, inst, inst.result_reg)
  inst.result_reg = reg
  add_reg_to_inst(func, inst, reg)
end

---@param func ILFunction
---@param inst ILGetTable|ILSetTable|ILSetList
---@param reg ILRegister
local function set_table_reg(func, inst, reg)
  assert_is_not_inst_group(inst)
  if reg == inst.table_reg then return end
  remove_reg_from_inst(func, inst, inst.table_reg)
  inst.table_reg = reg
  add_reg_to_inst(func, inst, reg)
end

---@param func ILFunction
---@param inst ILCall
---@param reg ILRegister
local function set_func_reg(func, inst, reg)
  assert_is_not_inst_group(inst)
  if reg == inst.func_reg then return end
  remove_reg_from_inst(func, inst, inst.func_reg)
  inst.func_reg = reg
  add_reg_to_inst(func, inst, reg)
end

---@param func ILFunction
---@param inst ILBinop
---@param ptr ILPointer
local function set_left_ptr(func, inst, ptr)
  assert_is_not_inst_group(inst)
  if ptr == inst.left_ptr then return end
  remove_ptr_from_inst(func, inst, inst.left_ptr)
  inst.left_ptr = ptr
  add_ptr_to_inst(func, inst, ptr)
end

---@param func ILFunction
---@param inst ILMove|ILSetUpval|ILSetTable|ILBinop|ILUnop|ILToNumber
---@param ptr ILPointer
local function set_right_ptr(func, inst, ptr)
  assert_is_not_inst_group(inst)
  if ptr == inst.right_ptr then return end
  remove_ptr_from_inst(func, inst, inst.right_ptr)
  inst.right_ptr = ptr
  add_ptr_to_inst(func, inst, ptr)
end

---@param func ILFunction
---@param inst ILGetTable|ILSetTable
---@param ptr ILPointer
local function set_key_ptr(func, inst, ptr)
  assert_is_not_inst_group(inst)
  if ptr == inst.key_ptr then return end
  remove_ptr_from_inst(func, inst, inst.key_ptr)
  inst.key_ptr = ptr
  add_ptr_to_inst(func, inst, ptr)
end

---@param func ILFunction
---@param inst ILTest
---@param ptr ILPointer
local function set_condition_ptr(func, inst, ptr)
  assert_is_not_inst_group(inst)
  if ptr == inst.condition_ptr then return end
  remove_ptr_from_inst(func, inst, inst.condition_ptr)
  inst.condition_ptr = ptr
  add_ptr_to_inst(func, inst, ptr)
end

----------------------------------------------------------------------------------------------------
-- helper functions for arrays of registers or pointers
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param array ILRegister[]
---@param index integer? @ Default: `#array + 1`
local function insert_reg_in_array(func, inst, reg, array, index)
  assert_is_not_inst_group(inst)
  if index then
    table.insert(array, index, reg)
  else
    array[#array+1] = reg
  end
  add_reg_to_inst(func, inst, reg)
end

---@param func ILFunction
---@param inst ILInstruction
---@param ptr ILPointer
---@param array ILPointer[]
---@param index integer? @ Default: `#array + 1`
local function insert_ptr_in_array(func, inst, ptr, array, index)
  assert_is_not_inst_group(inst)
  if index then
    table.insert(array, index, ptr)
  else
    array[#array+1] = ptr
  end
  add_ptr_to_inst(func, inst, ptr)
end

---Removes the first instance of the given register.
---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param array ILRegister[]
local function remove_reg_from_array(func, inst, reg, array)
  assert_is_not_inst_group(inst)
  util.remove_from_array(array, reg)
  remove_reg_from_inst(func, inst, reg)
end

---Removes the first instance of the given pointer.
---@param func ILFunction
---@param inst ILInstruction
---@param ptr ILPointer
---@param array ILPointer[]
local function remove_ptr_from_array(func, inst, ptr, array)
  assert_is_not_inst_group(inst)
  util.remove_from_array(array, ptr)
  remove_ptr_from_inst(func, inst, ptr)
end

---@param func ILFunction
---@param inst ILInstruction
---@param array ILRegister[]
---@param index integer? @ Default: `#array`
local function remove_reg_at(func, inst, array, index)
  assert_is_not_inst_group(inst)
  local reg_or_ptr = table.remove(array, index)
  remove_reg_from_inst(func, inst, reg_or_ptr)
end

---@param func ILFunction
---@param inst ILInstruction
---@param array ILPointer[]
---@param index integer? @ Default: `#array`
local function remove_ptr_at(func, inst, array, index)
  assert_is_not_inst_group(inst)
  local reg_or_ptr = table.remove(array, index)
  remove_ptr_from_inst(func, inst, reg_or_ptr)
end

---@param func ILFunction
---@param inst ILInstruction
---@param reg ILRegister
---@param array ILRegister[]
---@param index integer
local function set_reg_at(func, inst, reg, array, index)
  assert_is_not_inst_group(inst)
  remove_reg_from_inst(func, inst, array[index])
  array[index] = reg
  add_reg_to_inst(func, inst, reg)
end

---@param func ILFunction
---@param inst ILInstruction
---@param ptr ILPointer
---@param array ILPointer[]
---@param index integer
local function set_ptr_at(func, inst, ptr, array, index)
  assert_is_not_inst_group(inst)
  remove_ptr_from_inst(func, inst, array[index])
  array[index] = ptr
  add_ptr_to_inst(func, inst, ptr)
end

----------------------------------------------------------------------------------------------------
-- wrapper functions for result_regs for ILCall|ILVararg
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILCall|ILVararg
---@param reg ILRegister
---@param index integer? @ Default: `#inst.result_regs + 1`
local function insert_into_result_regs(func, inst, reg, index)
  insert_reg_in_array(func, inst, reg, inst.result_regs, index)
end

---@param func ILFunction
---@param inst ILCall|ILVararg
---@param reg ILRegister
local function remove_from_result_regs(func, inst, reg)
  remove_reg_from_array(func, inst, reg, inst.result_regs)
end

---@param func ILFunction
---@param inst ILCall|ILVararg
---@param index integer? @ Default: `#inst.result_regs`
local function remove_at_in_result_regs(func, inst, index)
  remove_reg_at(func, inst, inst.result_regs, index)
end

---@param func ILFunction
---@param inst ILCall|ILVararg
---@param reg ILRegister
---@param index integer
local function set_at_in_result_regs(func, inst, reg, index)
  set_reg_at(func, inst, reg, inst.result_regs, index)
end

----------------------------------------------------------------------------------------------------
-- wrapper functions for regs for ILCloseUp|ILScoping
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILCloseUp|ILScoping
---@param reg ILRegister
---@param index integer? @ Default: `#inst.regs + 1`
local function insert_into_regs(func, inst, reg, index)
  insert_reg_in_array(func, inst, reg, inst.regs, index)
end

---@param func ILFunction
---@param inst ILCloseUp|ILScoping
---@param reg ILRegister
local function remove_from_regs(func, inst, reg)
  remove_reg_from_array(func, inst, reg, inst.regs)
end

---@param func ILFunction
---@param inst ILCloseUp|ILScoping
---@param index integer? @ Default: `#inst.regs`
local function remove_at_in_regs(func, inst, index)
  remove_reg_at(func, inst, inst.regs, index)
end

---@param func ILFunction
---@param inst ILCloseUp|ILScoping
---@param reg ILRegister
---@param index integer
local function set_at_in_regs(func, inst, reg, index)
  set_reg_at(func, inst, reg, inst.regs, index)
end

----------------------------------------------------------------------------------------------------
-- wrapper functions for right_ptrs for ILSetList|ILConcat
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILSetList|ILConcat
---@param ptr ILPointer
---@param index integer? @ Default: `#inst.right_ptrs + 1`
local function insert_into_right_ptrs(func, inst, ptr, index)
  insert_ptr_in_array(func, inst, ptr, inst.right_ptrs, index)
end

---@param func ILFunction
---@param inst ILSetList|ILConcat
---@param ptr ILPointer
local function remove_from_right_ptrs(func, inst, ptr)
  remove_ptr_from_array(func, inst, ptr, inst.right_ptrs)
end

---@param func ILFunction
---@param inst ILSetList|ILConcat
---@param index integer? @ Default: `#inst.right_ptrs`
local function remove_at_in_right_ptrs(func, inst, index)
  remove_ptr_at(func, inst, inst.right_ptrs, index)
end

---@param func ILFunction
---@param inst ILSetList|ILConcat
---@param ptr ILPointer
---@param index integer
local function set_at_in_right_ptrs(func, inst, ptr, index)
  set_ptr_at(func, inst, ptr, inst.right_ptrs, index)
end

----------------------------------------------------------------------------------------------------
-- wrapper functions for arg_ptrs for ILCall
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILCall
---@param ptr ILPointer
---@param index integer? @ Default: `#inst.arg_ptrs + 1`
local function insert_into_arg_ptrs(func, inst, ptr, index)
  insert_ptr_in_array(func, inst, ptr, inst.arg_ptrs, index)
end

---@param func ILFunction
---@param inst ILCall
---@param ptr ILPointer
local function remove_from_arg_ptrs(func, inst, ptr)
  remove_ptr_from_array(func, inst, ptr, inst.arg_ptrs)
end

---@param func ILFunction
---@param inst ILCall
---@param index integer? @ Default: `#inst.arg_ptrs`
local function remove_at_in_arg_ptrs(func, inst, index)
  remove_ptr_at(func, inst, inst.arg_ptrs, index)
end

---@param func ILFunction
---@param inst ILCall
---@param ptr ILPointer
---@param index integer
local function set_at_in_arg_ptrs(func, inst, ptr, index)
  set_ptr_at(func, inst, ptr, inst.arg_ptrs, index)
end

----------------------------------------------------------------------------------------------------
-- wrapper functions for ptrs for ILRet
----------------------------------------------------------------------------------------------------

---@param func ILFunction
---@param inst ILRet
---@param ptr ILPointer
---@param index integer? @ Default: `#inst.ptrs + 1`
local function insert_into_ptrs(func, inst, ptr, index)
  insert_ptr_in_array(func, inst, ptr, inst.ptrs, index)
end

---@param func ILFunction
---@param inst ILRet
---@param ptr ILPointer
local function remove_from_ptrs(func, inst, ptr)
  remove_ptr_from_array(func, inst, ptr, inst.ptrs)
end

---@param func ILFunction
---@param inst ILRet
---@param index integer? @ Default: `#inst.ptrs`
local function remove_at_in_ptrs(func, inst, index)
  remove_ptr_at(func, inst, inst.ptrs, index)
end

---@param func ILFunction
---@param inst ILRet
---@param ptr ILPointer
---@param index integer
local function set_at_in_ptrs(func, inst, ptr, index)
  set_ptr_at(func, inst, ptr, inst.ptrs, index)
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- inserting
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param func ILFunction
---@param inst ILInstruction
local function update_reg_liveliness_for_new_inst(func, inst)
  assert_has_reg_liveliness(func, "update_reg_liveliness_for_new_inst")
  util.debug_assert(inst.prev_border or inst.next_border, "Cannot update reg liveliness for new instruction \z
    if its borders have not been updated yet. It is not the job of il_registers to update borders."
  )
  util.debug_assert(not inst.inst_group, "A newly inserted instruction must not be apart of an \z
    instruction group already. Insert all instructions first then group them together."
  )
  -- The borders update already initializes `live_regs` either as an empty array if the instruction was
  -- prepended or appended, or as a copy of the existing `live_regs` of the border where the instruction was
  -- inserted. That leaves this function with just adding the registers used by this instruction.
  ---@diagnostic disable-next-line: redefined-local
  visit_regs_for_inst(func, inst, function(func, inst, reg)
    -- Could directly pass the function to `visit_regs_for_inst` but that's more likely to break with changes.
    add_reg_to_inst(func, inst, reg)
  end)
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- removing
----====----====----====----====----====----====----====----====----====----====----====----====----

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
  -- creating

  create_reg_liveliness = create_reg_liveliness,
  create_reg_liveliness_recursive = create_reg_liveliness_recursive,
  ensure_has_reg_liveliness = ensure_has_reg_liveliness,
  ensure_has_reg_liveliness_recursive = ensure_has_reg_liveliness_recursive,

  -- modifying

  set_allow_modifying_inst_groups = set_allow_modifying_inst_groups,

  set_result_reg = set_result_reg,
  set_table_reg = set_table_reg,
  set_func_reg = set_func_reg,
  set_left_ptr = set_left_ptr,
  set_right_ptr = set_right_ptr,
  set_key_ptr = set_key_ptr,
  set_condition_ptr = set_condition_ptr,

  insert_into_result_regs = insert_into_result_regs,
  remove_from_result_regs = remove_from_result_regs,
  remove_at_in_result_regs = remove_at_in_result_regs,
  set_at_in_result_regs = set_at_in_result_regs,
  insert_into_regs = insert_into_regs,
  remove_from_regs = remove_from_regs,
  remove_at_in_regs = remove_at_in_regs,
  set_at_in_regs = set_at_in_regs,
  insert_into_right_ptrs = insert_into_right_ptrs,
  remove_from_right_ptrs = remove_from_right_ptrs,
  remove_at_in_right_ptrs = remove_at_in_right_ptrs,
  set_at_in_right_ptrs = set_at_in_right_ptrs,
  insert_into_arg_ptrs = insert_into_arg_ptrs,
  remove_from_arg_ptrs = remove_from_arg_ptrs,
  remove_at_in_arg_ptrs = remove_at_in_arg_ptrs,
  set_at_in_arg_ptrs = set_at_in_arg_ptrs,
  insert_into_ptrs = insert_into_ptrs,
  remove_from_ptrs = remove_from_ptrs,
  remove_at_in_ptrs = remove_at_in_ptrs,
  set_at_in_ptrs = set_at_in_ptrs,

  -- inserting

  update_reg_liveliness_for_new_inst = update_reg_liveliness_for_new_inst,
}
