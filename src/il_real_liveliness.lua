
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
---@param left ILLiveRegisterRange
---@param right ILLiveRegisterRange
local function mark_as_same(data, left, right)
  -- NOTE: The conditions here are intentionally redundant to make it clear when each block gets executed.
  local left_combined = data.combined_live_reg_ranges[left]
  local right_combined = data.combined_live_reg_ranges[right]
  if left_combined and right_combined and left_combined == right_combined then
    return -- Already marked as the same, nothing to do.
  end
  if not left_combined and not right_combined then
    ---@type ILCombinedLiveRegisterRange
    local result = {
      main_reg_range = left,
      other_reg_ranges = {right},
    }
    data.combined_live_reg_ranges[left] = result
    data.combined_live_reg_ranges[right] = result
    return
  end
  if left_combined and not right_combined then
    local result = left_combined
    left_combined.other_reg_ranges[#left_combined.other_reg_ranges+1] = right
    data.combined_live_reg_ranges[right] = result
    return
  end
  if not left_combined and right_combined then
    local result = right_combined
    right_combined.other_reg_ranges[#right_combined.other_reg_ranges+1] = left
    data.combined_live_reg_ranges[left] = result
    return
  end
  if left_combined and right_combined and left_combined ~= right_combined then
    local result = left_combined
    left_combined.other_reg_ranges[#left_combined.other_reg_ranges+1] = right_combined.main_reg_range
    data.combined_live_reg_ranges[right_combined.main_reg_range] = result
    for _, other in ipairs(right_combined.other_reg_ranges) do
      left_combined.other_reg_ranges[#left_combined.other_reg_ranges+1] = other
      data.combined_live_reg_ranges[other] = result
    end
    return
  end
  util.debug_abort("This is unreachable.")
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
        mark_as_same(data, reg_range, visited_reg_range)
      end
    elseif not regs_lut[reg_range.reg] then
      regs_lut[reg_range.reg] = reg_range
      regs_waiting_for_set[#regs_waiting_for_set+1] = reg_range
      anything_actually_changed = true
    elseif regs_lut[reg_range.reg] ~= reg_range then
      mark_as_same(data, reg_range, regs_lut[reg_range.reg])
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
      util.debug_abort("Attempt to add a live reg range for the same register at the same execution \z
        checkpoint twice."
      )
    end
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function push_open_block(data, open_block)
  util.debug_assert(not linq(data.open_blocks):contains(open_block))
  util.debug_assert(not data.open_blocks_lut[open_block.block])
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
  if partially_open_block then
    merge_open_blocks(data, partially_open_block, real_live_regs)
  else
    partially_open_block = new_open_block(block)
    partially_open_block.regs_waiting_for_set = util.shallow_copy(real_live_regs)
    partially_open_block.regs_lut = util.shallow_copy(regs_lut)
    add_partially_open_block(data, partially_open_block)
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
  util.debug_assert(data.previously_open_blocks[open_block.block])
  data.finished_blocks[open_block.block] = true

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

  -- This instance of `open_block` is not used anymore past this point, no need to clean it up.
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
local function add_to_param_execution_checkpoint(data, real_live_regs)
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
  for _, reg_range in ipairs(real_live_regs) do
    data.func.param_execution_checkpoint.live_range_by_reg[reg_range.reg] = reg_range
  end
end

---@param data ILRealLivelinessData
---@param open_block ILRealLivelinessOpenBlock
local function eval_live_regs_in_block(data, open_block)
  if open_block.is_first_pass then
    util.debug_assert(not data.first_passes[open_block.block])
    data.first_passes[open_block.block] = true
  end
  save_in_previously_open_blocks(data, open_block)

  local regs_waiting_for_set = open_block.regs_waiting_for_set
  local regs_lut = open_block.regs_lut
  for inst in il_blocks.iterate_reverse(data.func, open_block.block) do
    if inst.inst_type ~= "scoping" then
      visit_regs_for_inst_deduplicated(data, inst, function(_, _, reg, get_set)
        if reg.is_internal then return end
        local live_reg_range = regs_lut[reg]
        if bit32.band(get_set, set_flag) ~= 0 and live_reg_range then
          live_reg_range.set_insts[#live_reg_range.set_insts+1] = inst
          regs_lut[reg] = nil
          util.remove_from_array_fast(regs_waiting_for_set, live_reg_range)
          live_reg_range = nil ---@diagnostic disable-line: cast-local-type
        end
        if bit32.band(get_set, get_flag) ~= 0
          -- Closures are the only instructions where getting and setting a reg means it is not alive before.
          and (inst.inst_type ~= "closure" or bit32.band(get_set, set_flag) == 0)
        then
          if open_block.is_first_pass and not live_reg_range then
            -- Don't create new live reg ranges in additional passes, they'd be duplicates.
            live_reg_range = {reg = reg, set_insts = {}, get_insts = {}}
            regs_lut[reg] = live_reg_range
            regs_waiting_for_set[#regs_waiting_for_set+1] = live_reg_range
          end
          if not open_block.is_first_pass and live_reg_range then
            regs_lut[reg] = nil
            util.remove_from_array_fast(regs_waiting_for_set, live_reg_range)
            live_reg_range = nil ---@diagnostic disable-line: cast-local-type
          end
          if live_reg_range then
            live_reg_range.get_insts[#live_reg_range.get_insts+1] = inst
          end
        end

        -- Keep track of which instructions use a register which is captured as an upvalue, get and set.
        if open_block.is_first_pass and data.captured_reg_usage[reg] then
          data.captured_reg_usage[reg][inst] = get_set
        end
      end)
    end

    if not open_block.is_first_pass and not regs_waiting_for_set[1] then
      break
    end
    if inst ~= open_block.block.start_inst then
      add_to_real_live_regs(inst.prev_border, regs_waiting_for_set)
    end
  end

  -- Ensure the live regs before the main entry block are just the ones for parameters, anything else
  -- indicates that there are regs used before they are written to, which is invalid.
  if open_block.block.is_main_entry_block then
    add_to_param_execution_checkpoint(data, regs_waiting_for_set)
  end

  mark_as_finished(data, open_block)
end

---@param combined ILCombinedLiveRegisterRange
local function normalize_combined_reg_range(combined)
  if combined.has_been_normalized then return end
  combined.has_been_normalized = true
  local main_reg_range = combined.main_reg_range
  util.debug_assert(linq(combined.other_reg_ranges):all(function(r) return r.reg == main_reg_range.reg end))
  main_reg_range.get_insts = linq(main_reg_range.get_insts)
    :union(linq(combined.other_reg_ranges):select_many(function(r) return r.get_insts end))
    :to_array()
  main_reg_range.set_insts = linq(main_reg_range.set_insts)
    :union(linq(combined.other_reg_ranges):select_many(function(r) return r.set_insts end))
    :to_array()
  main_reg_range.is_param = main_reg_range.is_param
    or linq(combined.other_reg_ranges):any(function(r) return r.is_param end)
    or nil
end

---@param data ILRealLivelinessData
local function rename_live_reg_ranges(data)
  ---@param checkpoint ILExecutionCheckpoint
  local function replace_in_checkpoint(checkpoint)
    local list = checkpoint.real_live_regs
    local lut = checkpoint.live_range_by_reg
    for i, reg_range in ipairs(list) do
      local combined = data.combined_live_reg_ranges[reg_range]
      if combined and reg_range ~= combined.main_reg_range then
        normalize_combined_reg_range(combined)
        list[i] = combined.main_reg_range
        lut[reg_range.reg] = combined.main_reg_range
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

  replace_in_checkpoint(data.func.param_execution_checkpoint)
end

---@param data ILRealLivelinessData
---@param inst ILClosure
---@return ILRegister[]
local function get_captured_regs_for_inst(data, inst)
  local regs = data.captured_regs_by_closure[inst]
  if regs then return regs end
  regs = linq(inst.func.upvals)
    :where(function(upval) return upval.parent_type == "local" end)
    :select(function(upval) return upval.reg_in_parent_func end)
    :to_array()
  data.captured_regs_by_closure[inst] = regs
  return regs
end

---@param data ILRealLivelinessData
local function upvals_are_extra_special(data)
  -- Creating the live register ranges, which is done before this function, is pretty straight forward. One
  -- big reason for that is that it is done from back to front, which means that as soon as it finds an inst
  -- which is reading from a register, it knows that it must be alive before then. On the other hand, if it,
  -- were done from front to back, a register being written to does not guarantee it actually becoming alive,
  -- because when there's another write to the same register before it gets read from, the first write can be
  -- ignored.
  -- This logic can also create multiple live ranges for the same register, where it is not alive in between
  -- those two ranges. This is correct and ultimately an optimization.
  -- But then there are registers which get captured as upvalues by inner functions. These registers may
  -- require to stay alive in that exact time frame.
  -- The definition for when an upvalue register must be alive is that from the closure instruction which is
  -- capturing it it must stay alive - as the same live range - up to every instruction which gets or sets the
  -- register where said instructions are reachable from the closure instruction.
  -- Think of this example:
  --
  -- local foo = 100
  -- local _ = foo
  -- -- foo can be dead at this border.
  -- local bar = 200
  -- -- As well as at this border.
  -- foo = 300
  -- local function f() return foo end
  -- -- foo must be alive at this border.
  -- bar = 400
  -- -- And this border.
  -- foo = 500 -- This must write to the same live range as the one that's captured as an upvalue.
  -- return foo

  ---@class ILRealLivelinessOpenCapturedReg
  ---@field reg ILRegister
  ---@field live_range ILLiveRegisterRange
  ---@field checkpoints ILExecutionCheckpoint[]|{size: integer} @ A stack.

  ---@type ILRealLivelinessOpenCapturedReg[]
  local open_regs = {}
  ---@type table<ILRegister, true>
  local open_lut = {}

  ---The value is the registers which have all been open at the time of entering a given block at some point.
  ---It must keep track of this, because a block can be entered from multiple different blocks, each with
  ---potentially different open registers. However if all of said registers have been visited in a block
  ---before, it must not do so again otherwise it could turn into an infinite loop.
  ---@type table<ILBlock, table<ILRegister, true>>
  local visited_blocks = {}

  local walk_block
  ---@param link ILBlockLink
  local function walk_link(link)
    if link then
      for _, open in ipairs(open_regs) do
        stack.push(open.checkpoints, link)
      end
      walk_block(link.target_block)
      for _, open in ipairs(open_regs) do
        -- walk_block can clear the stack, only pop if it didn't do that.
        if stack.get_top(open.checkpoints) == link then
          stack.pop(open.checkpoints)
        else
          util.debug_assert(open.checkpoints.size == 0, "The only time the top checkpoint on the stack after calling \z
            walk_block does not equal the link that was pushed onto the stack right before it is when \z
            walk_block cleared the stack. Otherwise the link should be at top after leaving walk_block. \z
            However it isn't, and the stack size is not 0. Something got pushed and popped incorrectly."
          )
        end
      end
    end
  end

  ---It is fine if a checkpoint exists multiple times in the checkpoints stack, it'll just be a bit less
  ---performant. I'm fairly certain it can actually happen with loop blocks.
  ---@param open ILRealLivelinessOpenCapturedReg
  local function extend_reg_live_time(open)
    for i = 1, open.checkpoints.size do
      local checkpoint = open.checkpoints[i]
      local existing_live_range = checkpoint.live_range_by_reg[open.reg]
      if existing_live_range then
        local live_range = open.live_range
        live_range.set_insts = linq(live_range.set_insts):union(existing_live_range.set_insts):to_array()
        live_range.get_insts = linq(live_range.get_insts):union(existing_live_range.get_insts):to_array()
        util.remove_from_array_fast(checkpoint.real_live_regs, existing_live_range)
        -- I don't know if the following condition can actually happen, but it seems reasonable.
        local param_cp = data.func.param_execution_checkpoint
        if existing_live_range.is_param
          and param_cp.live_range_by_reg[existing_live_range.reg] == existing_live_range
        then
          live_range.is_param = true
          param_cp.live_range_by_reg[live_range.reg] = live_range
          util.replace_in_array(param_cp.real_live_regs, existing_live_range, live_range)
        end
      end
      checkpoint.real_live_regs[#checkpoint.real_live_regs+1] = open.live_range
      checkpoint.live_range_by_reg[open.reg] = open.live_range
    end
    open.checkpoints.size = 0
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  ---@return ILLiveRegisterRange?
  local function get_live_range_for_reg_on_prev(inst, reg)
    if inst ~= inst.block.start_inst then
      return inst.prev_border.live_range_by_reg[reg]
    end
    if inst.block.is_main_entry_block then
      return data.func.param_execution_checkpoint.live_range_by_reg[reg]
    end
    -- All source links must have the given live range, otherwise it'd be malformed. Just use the first one.
    return inst.block.source_links[1].live_range_by_reg[reg]
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  ---@return ILLiveRegisterRange?
  local function get_live_range_for_reg_on_next(inst, reg)
    if inst ~= inst.block.stop_inst then
      return inst.next_border.live_range_by_reg[reg]
    end
    local straight_link = inst.block.straight_link
    local jump_link = inst.block.jump_link
    return straight_link and straight_link.live_range_by_reg[reg]
      or jump_link and jump_link.live_range_by_reg[reg]
  end

  ---@param inst ILInstruction
  ---@param reg ILRegister
  ---@return ILLiveRegisterRange?
  local function get_live_range_for_reg(inst, reg)
    local reg_range = get_live_range_for_reg_on_prev(inst, reg)
    if reg_range or inst.inst_type ~= "closure" then return reg_range end
    return get_live_range_for_reg_on_next(inst, reg)
  end

  ---@param live_range ILLiveRegisterRange
  ---@return ILLiveRegisterRange
  local function to_captured_live_range(live_range)
    if live_range.is_captured_as_upval then return live_range end
    live_range.is_captured_as_upval = true
    return live_range
  end

  ---@param already_open ILRealLivelinessOpenCapturedReg[]
  local function restore_already_open(already_open)
    for _, open in ipairs(already_open) do
      open_regs[#open_regs+1] = open
    end
  end

  ---@param block ILBlock
  ---@param already_open ILRealLivelinessOpenCapturedReg
  ---@return boolean
  local function should_process_block(block, already_open)
    if not visited_blocks[block] then
      visited_blocks[block] = util.shallow_copy(open_lut)
      return true
    end

    local visited_regs = visited_blocks[block]
    local has_new_regs_to_visit = false
    for i = #open_regs, 1, -1 do
      local open = open_regs[i]
      if not visited_regs[open.reg] then
        visited_regs[open.reg] = true
        has_new_regs_to_visit = true
      else
        already_open[#already_open+1] = open
        open_regs[i] = open_regs[#open_regs]
        open_regs[#open_regs] = nil
        -- This does not touch open_lut, as the job of open_lut isn't to match open_regs, but to indicate
        -- that a given register should not be opened again. Since these registers here were already open
        -- when entering this block at some point in the past, there's no reason to have it process all of
        -- those again. Touching open_lut here would actually cause the same register to be opened twice in
        -- loop blocks where a closure captures said register inside the loop block.
      end
    end
    if has_new_regs_to_visit then
      return true
    end
    restore_already_open(already_open)
    return false
  end

  ---@param block ILBlock
  function walk_block(block)
    ---@type ILRealLivelinessOpenCapturedReg[]
    local already_open = {}
    if not should_process_block(block, already_open) then return end

    local opened_by_this_block
    local checkpoint_sizes_before_this_block = linq(open_regs)
      :to_dict(function(open) return open, open.checkpoints.size end)

    for inst in il_blocks.iterate(data.func, block) do
      for _, open in ipairs(open_regs) do
        if inst ~= block.start_inst then
          stack.push(open.checkpoints, inst.prev_border)
        end

        local get_set = data.captured_reg_usage[open.reg][inst]
        if get_set then
          -- Since blocks can be processed multiple times, only add it if it's not in the array already.
          if bit32.band(get_set, set_flag) ~= 0 and not linq(open.live_range.set_insts):contains(inst) then
            open.live_range.set_insts[#open.live_range.set_insts+1] = inst
          end
          extend_reg_live_time(open)
          checkpoint_sizes_before_this_block[open] = 0
        end
      end

      if inst.inst_type == "closure" then ---@cast inst ILClosure
        for _, reg in ipairs(get_captured_regs_for_inst(data, inst)) do
          if not open_lut[reg] then
            local live_range = get_live_range_for_reg(inst, reg)
            if live_range then
              ---@type ILRealLivelinessOpenCapturedReg
              local open = {
                reg = reg,
                live_range = to_captured_live_range(live_range),
                checkpoints = stack.new_stack(),
              }
              open_regs[#open_regs+1] = open
              open_lut[reg] = true
              opened_by_this_block = opened_by_this_block or {}
              opened_by_this_block[open] = true
            end
          end
        end
      end
    end

    -- These can change the order of regs in open_regs.
    walk_link(block.straight_link)
    walk_link(block.jump_link)

    if opened_by_this_block then
      util.remove_from_array_by_lut(open_regs, opened_by_this_block)
    end
    for _, open in ipairs(open_regs) do
      if open.checkpoints.size ~= 0 then
        util.debug_assert(checkpoint_sizes_before_this_block[open] <= open.checkpoints.size)
        open.checkpoints.size = checkpoint_sizes_before_this_block[open]
      end
    end
    restore_already_open(already_open)
  end

  walk_block(data.func.blocks.first)
end

---@param data ILRealLivelinessData
local function find_all_captured_regs(data)
  local captured_regs = data.captured_reg_usage
  local inst = data.func.instructions.first
  while inst do
    if inst.inst_type == "closure" then ---@cast inst ILClosure
      for _, reg in ipairs(get_captured_regs_for_inst(data, inst)) do
        if not captured_regs[reg] then
          captured_regs[reg] = {}
        end
      end
    end
    inst = inst.next
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

---@class ILCombinedLiveRegisterRange
---@field main_reg_range ILLiveRegisterRange
---@field other_reg_ranges ILLiveRegisterRange[]
---@field has_been_normalized boolean?

---@class ILRealLivelinessData
---@field func ILFunction
---@field partially_open_blocks_lut table<ILBlock, ILRealLivelinessOpenBlock>
---@field partially_open_blocks ILRealLivelinessOpenBlockList
---@field previously_open_blocks table<ILBlock, ILRealLivelinessOpenBlock>
---@field open_blocks ILRealLivelinessOpenBlock[] @ This is a stack.
---@field open_blocks_lut table<ILBlock, ILRealLivelinessOpenBlock> @ Lookup table for blocks in open_blocks.
---@field finished_blocks table<ILBlock, true>
---@field combined_live_reg_ranges table<ILLiveRegisterRange, ILCombinedLiveRegisterRange>
---Regs which are captured as upvalues by closure insts.
---@field captured_regs_by_closure table<ILInstruction, ILRegister[]>
---Instructions which get or set a register captured as an upval. The integer is a get/set bit field.
---@field captured_reg_usage table<ILRegister, table<ILInstruction, integer>>
---@field first_passes table<ILBlock, true> @ This exists purely for a debug assert, it's not actually used.

---@param func ILFunction
local function eval_real_reg_liveliness(func)
  func.param_execution_checkpoint = {
    real_live_regs = {},
    live_range_by_reg = {},
  }

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
    combined_live_reg_ranges = {},
    captured_regs_by_closure = {},
    captured_reg_usage = {},
    first_passes = {},
  }
  find_all_captured_regs(data)

  while true do
    while stack.get_top(data.open_blocks) do
      local open_block = stack.pop(data.open_blocks)
      data.open_blocks_lut[open_block.block] = nil
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
        eval_live_regs_in_block(data, partially_open_block)
        goto continue -- Go back to processing open blocks and new partially open blocks.
      end
    end

    break
    ::continue::
  end

  rename_live_reg_ranges(data)

  local param_cp = func.param_execution_checkpoint
  for _, param_reg in ipairs(func.param_regs) do
    local live_reg_range = param_cp.live_range_by_reg[param_reg]
    if live_reg_range then
      live_reg_range.is_param = true
      param_cp.real_live_regs[#param_cp.real_live_regs+1] = live_reg_range
    end
  end

  upvals_are_extra_special(data)
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
