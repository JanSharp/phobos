
local util = require("util")
local ll = require("linked_list")
local linq = require("linq")
local stack = require("stack")
local il_blocks = require("il_blocks")
local il_borders = require("il_borders")

----====----====----====----====----====----====----====----====----====----====----====----====----
-- utility
----====----====----====----====----====----====----====----====----====----====----====----====----

local visit_regs_for_inst
local visit_regs_for_inst_deduplicated
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

  ---@generic T
  ---@param data T @ A state object passed as is to the visit callback. Can be `nil`.
  ---@param inst ILInstruction
  ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
  function visit_regs_for_inst(data, inst, visit_reg_func)
    visit_reg = visit_reg_func
    visitor_lut[inst.inst_type](data, inst)
  end

  do
    local reg_flags_lut = {}
    local regs = {}
    local function callback(_, _, reg, get_set)
      if not reg_flags_lut[reg] then
        regs[#regs+1] = reg
      end
      reg_flags_lut[reg] = bit32.bor(reg_flags_lut[reg] or 0, get_set)
    end

    ---@generic T
    ---@param data T @ A state object passed as is to the visit callback. Can be `nil`.
    ---@param inst ILInstruction
    ---@param visit_reg_func fun(data: T, inst: ILInstruction, reg: ILRegister, get_set: 1|2|3)
    function visit_regs_for_inst_deduplicated(data, inst, visit_reg_func)
      visit_regs_for_inst(nil, inst, callback)
      for _, reg in ipairs(regs) do
        visit_reg_func(data, inst, reg, reg_flags_lut[reg])
      end
      util.clear_array(regs)
      util.clear_table(reg_flags_lut)
    end
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

---@param partially_open_block ILRealLivelinessOpenBlock
---@param regs_to_add ILLiveRegisterRange[]
---@return boolean anything_actually_changed
local function merge_partially_open_blocks(partially_open_block, regs_to_add)
  local regs_waiting_for_set = partially_open_block.regs_waiting_for_set
  local regs_lut = partially_open_block.regs_lut
  local anything_actually_changed = false
  for _, reg_range in ipairs(regs_to_add) do
    if not regs_lut[reg_range.reg] then
      regs_lut[reg_range.reg] = reg_range
      regs_waiting_for_set[#regs_waiting_for_set+1] = reg_range
      anything_actually_changed = true
    end
  end
  return anything_actually_changed
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function mark_as_finished(data, open_block)
  data.finished_blocks[open_block.block] = true

  ---@param link ILBlockLink
  ---@return boolean
  local function is_link_finished(link)
    return not link or data.finished_blocks[link.target_block]
  end

  for _, link in ipairs(open_block.block.source_links) do
    link.real_live_regs = util.shallow_copy(open_block.regs_waiting_for_set)

    local source_block = link.source_block
    if data.finished_blocks[source_block] then
      local previously_open_block = data.previously_open_blocks[source_block]
      if merge_partially_open_blocks(previously_open_block, open_block.regs_waiting_for_set) then
        stack.push(data.open_blocks, previously_open_block)
      end
      goto continue
    end

    local partially_open_block = data.partially_open_blocks[source_block]
    if not partially_open_block then
      partially_open_block = {
        block = source_block,
        regs_waiting_for_set = util.shallow_copy(open_block.regs_waiting_for_set),
        regs_lut = util.shallow_copy(open_block.regs_lut),
      }
      data.partially_open_blocks[source_block] = partially_open_block
    else
      merge_partially_open_blocks(partially_open_block, open_block.regs_waiting_for_set)
    end

    if is_link_finished(source_block.straight_link) and is_link_finished(source_block.jump_link) then
      stack.push(data.open_blocks, partially_open_block)
    end
    ::continue::
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function eval_live_regs_in_block(data, open_block)
  data.partially_open_blocks[open_block.block] = nil
  data.previously_open_blocks[open_block.block] = {
    block = open_block.block,
    regs_waiting_for_set = util.shallow_copy(open_block.regs_waiting_for_set),
    regs_lut = util.shallow_copy(open_block.regs_lut),
  }

  local regs_waiting_for_set = open_block.regs_waiting_for_set
  local regs_lut = open_block.regs_lut
  for inst in il_blocks.iterate_reverse(data.func, open_block.block) do
    if inst.inst_type ~= "scoping" then
      visit_regs_for_inst_deduplicated(data, inst, function(_, _, reg, get_set)
        local live_reg_range = regs_lut[reg]
        if bit32.band(get_set, set_flag) ~= 0 and regs_lut[reg] then
          regs_lut[reg] = nil
          util.remove_from_array_fast(regs_waiting_for_set, live_reg_range)
        end
        if bit32.band(get_set, get_flag) ~= 0 and not regs_lut[reg] then
          live_reg_range = {reg = reg}
          regs_lut[reg] = live_reg_range
          regs_waiting_for_set[#regs_waiting_for_set+1] = live_reg_range
        end
      end)
    end

    if inst ~= open_block.block.start_inst then
      inst.prev_border.real_live_regs = util.shallow_copy(regs_waiting_for_set)
    end
  end
  mark_as_finished(data, open_block)
end

---@param func ILFunction
---@return ILRealLivelinessOpenBlock[]
local function get_initial_open_blocks(func)
  return linq(ll.iterate(func.blocks)--[[@as fun(): ILBlock]])
    :where(function(block) return not block.straight_link and not block.jump_link end)
    :select(function(block)
      ---@type ILRealLivelinessOpenBlock
      local open_block = {
        block = block,
        regs_waiting_for_set = {},
        regs_lut = {},
      }
      return open_block
    end)
    :to_stack()
end

---@class ILRealLivelinessOpenBlock
---@field block ILBlock
---@field regs_waiting_for_set ILLiveRegisterRange[]
---@field regs_lut table<ILRegister, ILLiveRegisterRange>

---@class ILRealLivelinessData
---@field func ILFunction
---@field partially_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field previously_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field open_blocks ILRealLivelinessOpenBlock[] @ This is a stack.
---@field finished_blocks table<ILBlock, true>

---@param func ILFunction
local function eval_real_reg_liveliness(func)
  ---@type ILRealLivelinessData
  local data = {
    func = func,
    partially_open_blocks = {},
    previously_open_blocks = {},
    open_blocks = get_initial_open_blocks(func),
    finished_blocks = {},
  }

  while true do
    while stack.get_top(data.open_blocks) do
      eval_live_regs_in_block(data, stack.pop(data.open_blocks))
    end

    if next(data.partially_open_blocks) then -- There is still at least 1 loop block.
      -- Only blocks with 2 target links can ultimately run this logic, so only test blocks
      local _, partially_open_block = next(data.partially_open_blocks)
      eval_live_regs_in_block(data, partially_open_block)
      goto continue
    end

    -- Check if there's still some blocks that are unfinished. This only happens if there is either no
    -- return block at all or there is unreachable blocks (or unreachable block loops).
    for block in ll.iterate_reverse(func.blocks) do
      if not data.finished_blocks[block] then
        data.partially_open_blocks[block] = {
          block = block,
          regs_lut = {},
          regs_waiting_for_set = {},
        }
        goto continue
      end
    end

    break
    ::continue::
  end
  -- TODO: ensure the live regs before the main entry block are just he ones for parameters, anything else [...]
  -- indicates that there are regs used before they are written to, which is invalid.
end

---@param func ILFunction
local function create_real_reg_liveliness(func)
  util.debug_assert(not func.has_real_reg_liveliness, "The create_reg_liveliness function is meant to be run \z
    for the initial creation of reg liveliness, however the given function already has reg liveliness."
  )
  func.has_real_reg_liveliness = true

  il_blocks.ensure_has_blocks(func)
  il_borders.ensure_has_borders(func)
  eval_real_reg_liveliness(func)
end

---@param func ILFunction
local function create_real_reg_liveliness_recursive(func)
  create_real_reg_liveliness(func)
  for _, inner_func in ipairs(func.inner_functions) do
    create_real_reg_liveliness_recursive(inner_func)
  end
end

---@param func ILFunction
local function ensure_has_real_reg_liveliness(func)
  if func.has_real_reg_liveliness then return end
  create_real_reg_liveliness(func)
end

---@param func ILFunction
local function ensure_has_real_reg_liveliness_recursive(func)
  ensure_has_real_reg_liveliness(func)
  for _, inner_func in ipairs(func.inner_functions) do
    ensure_has_real_reg_liveliness_recursive(inner_func)
  end
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- modifying
----====----====----====----====----====----====----====----====----====----====----====----====----

-- NOTE: At the moment, real live regs do not support being modified after evaluation.

----====----====----====----====----====----====----====----====----====----====----====----====----
-- inserting
----====----====----====----====----====----====----====----====----====----====----====----====----

-- NOTE: At the moment, real live regs do not support being modified after evaluation.

----====----====----====----====----====----====----====----====----====----====----====----====----
-- removing
----====----====----====----====----====----====----====----====----====----====----====----====----

-- NOTE: At the moment, real live regs do not support being modified after evaluation.

return {
  create_real_reg_liveliness = create_real_reg_liveliness,
  create_real_reg_liveliness_recursive = create_real_reg_liveliness_recursive,
  ensure_has_real_reg_liveliness = ensure_has_real_reg_liveliness,
  ensure_has_real_reg_liveliness_recursive = ensure_has_real_reg_liveliness_recursive,
}
