
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

---@param block ILBlock
---@return ILRealLivelinessOpenBlock
local function new_open_block(block)
  ---@type ILRealLivelinessOpenBlock
  local open_block = {
    block = block,
    is_first_pass = true,
    previously_visited_regs = {},
    regs_waiting_for_set = {},
    regs_lut = {},
  }
  return open_block
end

---@param data ILRealLivelinessData
---@param partially_open_block ILRealLivelinessOpenBlock
---@param regs_to_add ILLiveRegisterRange[]
---@return boolean anything_actually_changed
local function merge_open_blocks(data, partially_open_block, regs_to_add)
  local visited_lut = partially_open_block.previously_visited_regs
  local regs_waiting_for_set = partially_open_block.regs_waiting_for_set
  local regs_lut = partially_open_block.regs_lut
  local anything_actually_changed = false
  for _, reg_range in ipairs(regs_to_add) do
    local visited_reg_range = visited_lut[reg_range.reg]
    if visited_reg_range then
      if reg_range ~= visited_reg_range then
        reg_range.set_insts = linq(visited_reg_range.set_insts)
          :union(reg_range.set_insts)
          :to_array()
        data.renamed_live_reg_ranges[visited_reg_range] = reg_range
      end
    else
      regs_lut[reg_range.reg] = reg_range
      regs_waiting_for_set[#regs_waiting_for_set+1] = reg_range
      anything_actually_changed = true
    end
  end
  return anything_actually_changed
end

---@param execution_checkpoint ILExecutionCheckpoint
---@param real_live_regs ILLiveRegisterRange[]
local function add_to_real_live_regs(execution_checkpoint, real_live_regs)
  execution_checkpoint.real_live_regs = execution_checkpoint.real_live_regs or {}
  execution_checkpoint.live_range_by_reg = execution_checkpoint.live_range_by_reg or {}
  local list = execution_checkpoint.real_live_regs
  local lut = execution_checkpoint.live_range_by_reg
  for _, live_reg in ipairs(real_live_regs) do
    if not lut[live_reg.reg] then
      list[#list+1] = live_reg
      lut[live_reg.reg] = live_reg
    else
      util.debug_abort("Attempt to add a live reg range for the same register twice.")
    end
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function push_open_block(data, open_block)
  stack.push(data.open_blocks, open_block)
  data.open_blocks_lut[open_block.block] = open_block
end

---@param data ILRealLivelinessData
---@param partially_open_block ILRealLivelinessOpenBlock
local function add_partially_open_block(data, partially_open_block)
  ll.append(data.partially_open_blocks, partially_open_block)
  data.partially_open_blocks_lut[partially_open_block.block] = partially_open_block
end

---@param data ILRealLivelinessData
---@param partially_open_block ILRealLivelinessOpenBlock
local function remove_partially_open_block(data, partially_open_block)
  ll.remove(data.partially_open_blocks, partially_open_block)
  data.partially_open_blocks_lut[partially_open_block.block] = nil
end

---@param data ILRealLivelinessData
---@param block ILBlock
---@param real_live_regs ILLiveRegisterRange[]
---@param regs_lut table<ILRegister, ILLiveRegisterRange>
---@return ILRealLivelinessOpenBlock
local function add_to_waiting_regs(data, block, real_live_regs, regs_lut)
  if data.finished_blocks[block] then
    local previously_open_block = data.previously_open_blocks[block]
    if merge_open_blocks(data, previously_open_block, real_live_regs) then
      data.finished_blocks[block] = nil
      data.previously_open_blocks[block] = nil
      push_open_block(data, previously_open_block)
    end
    return previously_open_block
  end

  local already_open_block = data.open_blocks_lut[block]
  if already_open_block then
    merge_open_blocks(data, already_open_block, real_live_regs)
    return already_open_block
  end

  local partially_open_block = data.partially_open_blocks_lut[block]
  if not partially_open_block then
    partially_open_block = new_open_block(block)
    partially_open_block.regs_waiting_for_set = util.shallow_copy(real_live_regs)
    partially_open_block.regs_lut = util.shallow_copy(regs_lut)
    add_partially_open_block(data, partially_open_block)
  else
    merge_open_blocks(data, partially_open_block, real_live_regs)
  end
  return partially_open_block
end

---@param data ILRealLivelinessData
---@param link ILBlockLink
---@return boolean
local function is_link_finished(data, link)
  return not link or data.finished_blocks[link.target_block]
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function mark_as_finished(data, open_block)
  util.debug_assert(not data.partially_open_blocks_lut[open_block.block])
  data.finished_blocks[open_block.block] = true
  open_block.is_first_pass = false

  for _, link in ipairs(open_block.block.source_links) do
    add_to_real_live_regs(link, open_block.regs_waiting_for_set)

    local source_block = link.source_block
    local source_open_block = add_to_waiting_regs(data, source_block, open_block.regs_waiting_for_set, open_block.regs_lut)

    if not data.finished_blocks[source_block]
      and not data.open_blocks_lut[source_block]
      and is_link_finished(data, source_block.straight_link)
      and is_link_finished(data, source_block.jump_link)
    then
      if data.partially_open_blocks_lut[source_block] then -- It may not be partially open.
        remove_partially_open_block(data, source_open_block)
      end
      push_open_block(data, source_open_block)
    end
  end

  -- Mark as visited and clear waiting.
  for i = 1, #open_block.regs_waiting_for_set do
    local live_reg = open_block.regs_waiting_for_set[i]
    open_block.previously_visited_regs[live_reg.reg] = live_reg
    open_block.regs_waiting_for_set[i] = nil
    open_block.regs_lut[live_reg.reg] = nil
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function save_in_previously_open_blocks(data, open_block)
  ---@type ILRealLivelinessOpenBlock
  local saved = new_open_block(open_block.block)
  saved.is_first_pass = false
  saved.previously_visited_regs = util.shallow_copy(open_block.previously_visited_regs)
  for _, reg_range in ipairs(open_block.regs_waiting_for_set) do
    saved.previously_visited_regs[reg_range.reg] = reg_range
  end
  -- previously_open_blocks is separate from finished_blocks because it must capture the state
  -- before actually processing the block, while marking as finished happens after.
  data.previously_open_blocks[saved.block] = saved
end

---@param data ILRealLivelinessData
---@param real_live_regs ILLiveRegisterRange[]
local function add_to_param_live_reg_range_lut(data, real_live_regs)
  local invalid_regs = linq(real_live_regs)
    :select(function(reg_range) return reg_range.reg end)
    :except(data.func.param_regs)
    :select(function(reg) return reg.name or phobos_consts.unnamed_register_name end)
    :to_array()
  if invalid_regs[1] then
    util.debug_abort(#invalid_regs.." registers are read from before they are written to: "
      ..table.concat(invalid_regs, ", ").."."
    )
  end
  data.func.param_live_reg_range_lut = data.func.param_live_reg_range_lut or {}
  for _, reg_range in ipairs(real_live_regs) do
    data.func.param_live_reg_range_lut[reg_range.reg] = reg_range
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function eval_live_regs_in_block(data, open_block)
  save_in_previously_open_blocks(data, open_block)

  local regs_waiting_for_set = open_block.regs_waiting_for_set
  local regs_lut = open_block.regs_lut
  for inst in il_blocks.iterate_reverse(data.func, open_block.block) do
    if inst.inst_type ~= "scoping" then
      visit_regs_for_inst_deduplicated(data, inst, function(_, _, reg, get_set)
        if reg.is_internal then return end
        local live_reg_range = regs_lut[reg]
        if bit32.band(get_set, set_flag) ~= 0 and regs_lut[reg] then
          if not linq(live_reg_range.set_insts):contains(inst) then
            live_reg_range.set_insts[#live_reg_range.set_insts+1] = inst
          end
          regs_lut[reg] = nil
          util.remove_from_array_fast(regs_waiting_for_set, live_reg_range)
        end
        if open_block.is_first_pass and bit32.band(get_set, get_flag) ~= 0 and not regs_lut[reg] then
          -- Don't create new live reg ranges in additional passes, they'd be duplicates.
          live_reg_range = {reg = reg, set_insts = {}}
          regs_lut[reg] = live_reg_range
          regs_waiting_for_set[#regs_waiting_for_set+1] = live_reg_range
        end
      end)
    end

    if inst ~= open_block.block.start_inst then
      add_to_real_live_regs(inst.prev_border, regs_waiting_for_set)
    end
  end

  -- Ensure the live regs before the main entry block are just the ones for parameters, anything else
  -- indicates that there are regs used before they are written to, which is invalid.
  if open_block.block.is_main_entry_block then
    add_to_param_live_reg_range_lut(data, regs_waiting_for_set)
  end

  mark_as_finished(data, open_block)
end

---@param lut table<ILLiveRegisterRange, ILLiveRegisterRange>
---@return table<ILLiveRegisterRange, ILLiveRegisterRange>
local function normalize_renamed_lut(lut)
  for from, to in pairs(lut) do
    while lut[to] do
      to = lut[to]
    end
    lut[from] = to
  end
  return lut
end

---@param data ILRealLivelinessData
local function rename_live_reg_ranges(data)
  local renamed_lut = normalize_renamed_lut(data.renamed_live_reg_ranges)
  ---@param checkpoint ILExecutionCheckpoint
  local function replace_in_checkpoint(checkpoint)
    local list = checkpoint.real_live_regs
    local lut = checkpoint.live_range_by_reg
    for i, reg_range in ipairs(list) do
      local renamed = renamed_lut[reg_range]
      if renamed then
        list[i] = renamed
        lut[renamed.reg] = renamed
      end
    end
  end

  for border in il_borders.iterate_borders(data.func) do
    if border.real_live_regs then
      replace_in_checkpoint(border)
    end
  end

  local block = data.func.blocks.first
  while block do
    for _, link in ipairs(block.source_links) do
      replace_in_checkpoint(link)
    end
    block = block.next
  end

  for reg, reg_range in pairs(data.func.param_live_reg_range_lut) do
    if renamed_lut[reg_range] then
      data.func.param_live_reg_range_lut[reg] = renamed_lut[reg_range]
    end
  end
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
---@field is_first_pass boolean
---@field previously_visited_regs table<ILRegister, ILLiveRegisterRange>
---@field regs_waiting_for_set ILLiveRegisterRange[]
---@field regs_lut table<ILRegister, ILLiveRegisterRange> @ Lookup table for regs_waiting_for_set.
---@field next_partially_open_block ILRealLivelinessOpenBlock?
---@field prev_partially_open_block ILRealLivelinessOpenBlock?

---@class ILRealLivelinessOpenBlockList
---@field first ILRealLivelinessOpenBlock?
---@field last ILRealLivelinessOpenBlock?

---@class ILRealLivelinessData
---@field func ILFunction
---@field partially_open_blocks_lut table<ILBlock, ILRealLivelinessOpenBlock>
---@field partially_open_blocks ILRealLivelinessOpenBlockList
---@field previously_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field open_blocks ILRealLivelinessOpenBlock[] @ This is a stack.
---@field open_blocks_lut table<ILBlock, ILRealLivelinessOpenBlock> @ Lookup table for blocks in open_blocks.
---@field finished_blocks table<ILBlock, true>
---@field renamed_live_reg_ranges table<ILLiveRegisterRange, ILLiveRegisterRange>

---@param func ILFunction
local function eval_real_reg_liveliness(func)
  local open_blocks = get_initial_open_blocks(func)
  ---@type ILRealLivelinessData
  local data = {
    func = func,
    partially_open_blocks_lut = {},
    partially_open_blocks = ll.new_list("partially_open_block"),
    previously_open_blocks = {},
    open_blocks = open_blocks,
    open_blocks_lut = linq(open_blocks):to_dict(function(open_block) return open_block.block, open_block end),
    finished_blocks = {},
    renamed_live_reg_ranges = {},
  }

  while true do
    while stack.get_top(data.open_blocks) do
      local open_block = stack.pop(data.open_blocks)
      eval_live_regs_in_block(data, open_block)
      -- data.open_blocks_lut[open_block.block] = open_block
    end

    do
      local partially_open_block = data.partially_open_blocks.first
      if partially_open_block then -- There is still at least 1 loop block.
        -- Only blocks with 2 target links can ultimately run this logic, so only test blocks.
        remove_partially_open_block(data, partially_open_block)
        eval_live_regs_in_block(data, partially_open_block)
        goto continue
      end
    end

    -- Check if there's still some blocks that are unfinished. This only happens if there is either no
    -- return block at all or there is unreachable blocks (or unreachable block loops).
    for block in ll.iterate_reverse(func.blocks) do
      if not data.finished_blocks[block] then
        local partially_open_block = new_open_block(block)
        add_partially_open_block(data, partially_open_block)
        eval_live_regs_in_block(data, partially_open_block)
        goto continue -- Go back to processing open blocks and new partially open blocks.
      end
    end

    break
    ::continue::
  end

  rename_live_reg_ranges(data)

  for _, live_reg_range in pairs(func.param_live_reg_range_lut) do
    util.debug_assert(not live_reg_range.set_insts[1], "A live register range for a parameter should be \z
      impossible to have instructions that supposedly set the live register range."
    )
    live_reg_range.set_insts = nil
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
