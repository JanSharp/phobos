
local util = require("util")
local ll = require("linked_list")
local linq = require("linq")
local stack = require("stack")
local il_blocks = require("il_blocks")
local il_borders = require("il_borders")
local phobos_consts = require("constants")
local il_registers = require("il_registers")

----====----====----====----====----====----====----====----====----====----====----====----====----
-- utility
----====----====----====----====----====----====----====----====----====----====----====----====----

local visit_regs_for_inst_deduplicated = il_registers.visit_regs_for_inst_deduplicated
local get_flag = il_registers.get_flag
local set_flag = il_registers.set_flag

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

---@param execution_checkpoint ILExecutionCheckpoint
---@param real_live_regs ILLiveRegisterRange[]
local function set_real_live_regs(execution_checkpoint, real_live_regs)
  execution_checkpoint.real_live_regs = util.shallow_copy(real_live_regs)
  execution_checkpoint.live_range_by_reg = linq(real_live_regs):to_dict(function(live_reg_range)
    return live_reg_range.reg, live_reg_range
  end)
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
    set_real_live_regs(link, open_block.regs_waiting_for_set)

    local source_block = link.source_block

    if data.finished_blocks[source_block] then
      local previously_open_block = data.previously_open_blocks[source_block]
      if merge_partially_open_blocks(previously_open_block, open_block.regs_waiting_for_set) then
        stack.push(data.open_blocks, previously_open_block)
        data.open_blocks_lut[source_block] = true
        -- Theoretically these 2 lines are optional, I think, but this should be cleaner.
        data.finished_blocks[source_block] = nil
        data.previously_open_blocks[source_block] = nil
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

    if not data.open_blocks_lut[source_block]
      and is_link_finished(source_block.straight_link)
      and is_link_finished(source_block.jump_link)
    then
      stack.push(data.open_blocks, partially_open_block)
      data.open_blocks_lut[source_block] = true
    end
    ::continue::
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function eval_live_regs_in_block(data, open_block)
  data.partially_open_blocks[open_block.block] = nil
  -- previously_open_blocks is separate from finished_blocks because it must capture the state
  -- before actually processing the block, while marking as finished happens after.
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
        if reg.is_internal then return end
        local live_reg_range = regs_lut[reg]
        if bit32.band(get_set, set_flag) ~= 0 and regs_lut[reg] then
          live_reg_range.set_inst = inst
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
      set_real_live_regs(inst.prev_border, regs_waiting_for_set)
    end
  end

  -- Ensure the live regs before the main entry block are just the ones for parameters, anything else
  -- indicates that there are regs used before they are written to, which is invalid.
  if open_block.block.is_main_entry_block then
    local invalid_regs = linq(regs_waiting_for_set)
      :select(function(reg_range) return reg_range.reg end)
      :except(data.func.param_regs)
      :select(function(reg) return reg.name or phobos_consts.unnamed_register_name end)
      :to_array()
    if invalid_regs[1] then
      util.debug_abort(#invalid_regs.." registers are read from before they are written to: "
        ..table.concat(invalid_regs, ", ").."."
      )
    end
    data.func.param_live_reg_range_lut = linq(regs_waiting_for_set)
      :to_dict(function(reg_range) return reg_range.reg, reg_range end)
  end

  mark_as_finished(data, open_block)
end

---@param block ILBlock
---@return ILRealLivelinessOpenBlock
local function new_open_block(block)
  ---@type ILRealLivelinessOpenBlock
  local open_block = {
    block = block,
    regs_waiting_for_set = {},
    regs_lut = {},
  }
  return open_block
end

---@param func ILFunction
---@return ILRealLivelinessOpenBlock[]
local function get_initial_open_blocks(func)
  return linq(ll.iterate(func.blocks)--[[@as fun(): ILBlock]])
    :where(function(block) return not block.straight_link and not block.jump_link end)
    :select(function(block) return new_open_block(block) end)
    :to_stack()
end

---@class ILRealLivelinessOpenBlock
---@field block ILBlock
---@field regs_waiting_for_set ILLiveRegisterRange[]
---@field regs_lut table<ILRegister, ILLiveRegisterRange> @ Lookup table for regs_waiting_for_set.

---@class ILRealLivelinessData
---@field func ILFunction
---@field partially_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field previously_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field open_blocks ILRealLivelinessOpenBlock[] @ This is a stack.
---@field open_blocks_lut table<ILBlock, true> @ Lookup table for blocks in open_blocks.
---@field finished_blocks table<ILBlock, true>

---@param func ILFunction
local function eval_real_reg_liveliness(func)
  local open_blocks = get_initial_open_blocks(func)
  ---@type ILRealLivelinessData
  local data = {
    func = func,
    partially_open_blocks = {},
    previously_open_blocks = {},
    open_blocks = open_blocks,
    open_blocks_lut = linq(open_blocks):to_lookup(function(open_block) return open_block.block end),
    finished_blocks = {},
  }

  while true do
    while stack.get_top(data.open_blocks) do
      local open_block = stack.pop(data.open_blocks)
      eval_live_regs_in_block(data, open_block)
      data.open_blocks_lut[open_block.block] = true
    end

    if next(data.partially_open_blocks) then -- There is still at least 1 loop block.
      -- Only blocks with 2 target links can ultimately run this logic, so only test blocks.
      local _, partially_open_block = next(data.partially_open_blocks)
      eval_live_regs_in_block(data, partially_open_block)
      goto continue
    end

    -- Check if there's still some blocks that are unfinished. This only happens if there is either no
    -- return block at all or there is unreachable blocks (or unreachable block loops).
    for block in ll.iterate_reverse(func.blocks) do
      if not data.finished_blocks[block] then
        local partially_open_block = new_open_block(block)
        data.partially_open_blocks[block] = partially_open_block
        eval_live_regs_in_block(data, partially_open_block)
        goto continue -- Go back to processing open blocks and new partially open blocks.
      end
    end

    break
    ::continue::
  end

  for _, live_reg_range in pairs(func.param_live_reg_range_lut) do
    util.debug_assert(not live_reg_range.set_inst, "A live register range for a parameter should be \z
      impossible to have an instruction that supposedly sets the live register range."
    )
    live_reg_range.is_param = true
  end
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
