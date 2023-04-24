
local util = require("util")
local ll = require("linked_list")
local linq = require("linq")

-- NOTE: definition of blocks:
-- A block is a list of instructions which will be executed in order without any branches.
-- Blocks can have an arbitrary amount of source_links which are blocks potentially branching
-- into the block and may have 0 to 2 target links which are blocks they are potentially branching
-- to themselves. It depends on the last instruction of the block:
-- "ret" - 0 target links
-- "jump" - 1 target links
-- "test" - 2 target links
-- any other instruction - 1 target links
--
-- Labels are only valid as the very first instruction of a block.
--
-- Links are considered to be loop links if the target_block comes before the source_block
-- this is not 100% accurate but it is close enough.

---@param start_inst ILInstruction
---@param stop_inst ILInstruction
---@return ILBlock
local function new_block(start_inst, stop_inst)
  return {
    source_links = {},
    start_inst = start_inst,
    stop_inst = stop_inst,
  }
end

---@param block ILBlock
---@return fun(): ILBlockLink?
local function iterate_target_links(block)
  local checked_state = 0
  return function()
    while checked_state < 2 do
      checked_state = checked_state + 1
      if checked_state == 1 and block.straight_link then return block.straight_link end
      if checked_state == 2 and block.jump_link then return block.jump_link end
    end
  end
end

---@param source_block ILBlock
---@param target_block ILBlock
---@param is_jump_link boolean? @ is this the `jump_link`, not the `straight_link`?
---@return ILBlockLink
local function create_link(source_block, target_block, is_jump_link)
  local link = {
    source_block = source_block,
    target_block = target_block,
    -- backwards jumps are 99% of the time a loop
    -- I'm not sure how to detect if it is a loop otherwise, but since this is 99% of the time correct
    -- it's good enough. Besides, a jump being marked as a loop even though it isn't doesn't cause harm
    -- while a jump that is a loop not being marked as a loop does cause harm
    is_loop = target_block.start_inst.index < source_block.start_inst.index,
    is_jump_link = is_jump_link,
  }
  if is_jump_link then
    source_block.jump_link = link
  else
    source_block.straight_link = link
  end
  target_block.source_links[#target_block.source_links+1] = link
  return link
end

---@param block ILBlock
local function create_target_links_for_block(block)
  local last_inst = block.stop_inst
  local function assert_next()
    util.debug_assert(last_inst.next, "The next instruction of the last instruction of a block \z
      where the last instruction in the block is not a 'ret' or 'jump' instruction should be \z
      impossible to be nil."
    )
  end
  local inst_type = last_inst.inst_type
  if inst_type == "jump" then
    ---@cast last_inst ILJump
    create_link(block, last_inst.label.block, true)
  elseif inst_type == "test" then
    ---@cast last_inst ILTest
    assert_next()
    create_link(block, last_inst.next.block)
    create_link(block, last_inst.label.block, true)
  elseif inst_type == "ret" then
    -- doesn't link to anything
  else -- anything else just continues to the next block
    assert_next()
    create_link(block, last_inst.next.block)
  end
end

---label isn't in this list because labels can be the start of a block
---but if a label is not the first instruction in a block then it does still end the block
---so it's handled in the loop down below
local block_ends_lut = util.invert{"jump", "test", "ret"}

---@param left_inst ILInstruction
---@param right_inst ILInstruction
---@return boolean
local function can_use_same_block(left_inst, right_inst)
  return not block_ends_lut[left_inst.inst_type] and right_inst.inst_type ~= "label"
end

---@param start_inst ILInstruction
---@return ILBlock
local function create_block(start_inst)
  local block = new_block(start_inst, (nil)--[[@as ILInstruction]])
  start_inst.block = block
  local stop_inst = start_inst
  local inst = start_inst.next
  while inst and can_use_same_block(stop_inst, inst) do
    inst.block = block
    stop_inst = inst
    inst = inst.next
  end
  block.stop_inst = stop_inst
  return block
end

---@param func ILFunction
local function create_unlinked_blocks(func)
  local inst = func.instructions.first
  local blocks = ll.new_list()
  func.blocks = blocks
  while inst do
    local block = create_block(inst)
    ll.append(blocks, block)
    inst = block.stop_inst.next
  end
end

---@param func ILFunction
local function create_links_for_blocks(func)
  local blocks = func.blocks
  blocks.first.is_main_entry_block = true
  local block = blocks.first
  while block do
    create_target_links_for_block(block)
    block = block.next
  end
end

---@param func ILFunction
local function create_blocks(func)
  util.debug_assert(not func.has_blocks, "The create_blocks function is meant to be run for the initial \z
    creation of blocks, however the given function already has blocks."
  )
  func.has_blocks = true
  func.blocks = {}
  create_unlinked_blocks(func)
  create_links_for_blocks(func)
end

---@param func ILFunction
local function create_blocks_recursive(func)
  create_blocks(func)
  for _, inner_func in ipairs(func.inner_functions) do
    create_blocks_recursive(inner_func)
  end
end

---@param func ILFunction
local function ensure_has_blocks(func)
  if func.has_blocks then return end
  create_blocks(func)
end

---@param func ILFunction
local function ensure_has_blocks_recursive(func)
  ensure_has_blocks(func)
  for _, inner_func in ipairs(func.inner_functions) do
    ensure_has_blocks_recursive(inner_func)
  end
end

---@param func ILFunction
---@param func_name string
local function assert_has_blocks(func, func_name)
  util.debug_assert(func.has_blocks, "Attempt to use 'il_blocks."..func_name.."' with a func without blocks.")
end

---@param link ILBlockLink
---@param block ILBlock
local function set_link_target_block(link, block)
  util.remove_from_array_fast(link.target_block.source_links, link)
  link.target_block = block
  block.source_links[#block.source_links+1] = link
end

---Assumes that the checks making sure that inst cannot use an existing block have already been done.\
---Creates a new block which starts and stops at `inst`.\
---Updates existing blocks links.\
---Creates new block links.\
---Updates `is_main_entry_block`.
---@param func ILFunction
---@param inst ILInstruction
local function create_and_insert_block(func, inst)
  local block = new_block(inst, inst)
  inst.block = block
  ll.insert_after(func.blocks, inst.prev and inst.prev.block, block) -- If prev is nil, it'll prepend.

  -- Update link from `inst.perv` to `inst.next`, if it exists.
  if inst.prev and inst.prev.block.straight_link then
    set_link_target_block(inst.prev.block.straight_link, block)
  end

  -- Only when creating a new block there's a chance that the block with is_main_entry_block changes.
  if not inst.prev then
    inst.block.is_main_entry_block = true
    -- `inst.next` is guaranteed to be non nil, since empty instruction lists are malformed
    -- and `inst` is newly inserted, so there's at least 2 instructions right now.
    inst.next.block.is_main_entry_block = nil
  end

  -- Since there is no instruction which both ends and starts a block,
  -- there is no way for this insertion to cause a split of blocks.
  -- That means all blocks have been updated and set at this point, it's just the new block that is missing
  -- target links. Creating them is easy:
  create_target_links_for_block(block)
  -- Done.
end

---Does not create target links for the left side of the split,
---also does not create source links for the right side of the split.\
---These are potentially malformed blocks if not handled separately.
---
---If there is a gap between stop_inst and start_inst, the `block` field of those insts will remain untouched,
---therefore become malformed if not handled separately.
---@param func ILFunction
---@param block ILBlock
---@param stop_inst ILInstruction @ the stop inst for the left side of the split
---@param start_inst ILInstruction @ the start inst for the right side of the split
---@return ILBlock left_block
---@return ILBlock right_block
local function split_block(func, block, stop_inst, start_inst)
  local left_block = block
  local right_block = new_block(start_inst, block.stop_inst)
  ll.insert_after(func.blocks, left_block, right_block)
  left_block.stop_inst = stop_inst
  -- Moving target links to the new, right block
  right_block.straight_link = left_block.straight_link
  right_block.jump_link = left_block.jump_link
  left_block.straight_link = nil
  left_block.jump_link = nil
  for target_link in iterate_target_links(right_block) do
    target_link.source_block = right_block
  end
  -- Updating the `block` field for instructions.
  local inst = right_block.start_inst
  while true do
    inst.block = right_block
    if inst == right_block.stop_inst then break end
    inst = inst.next
  end
  return left_block, right_block
end

---@param func ILFunction
---@param inst ILInstruction @ the already inserted new instruction
local function update_blocks_for_new_inst(func, inst)
  assert_has_blocks(func, "update_blocks_for_new_inst")
  -- try to use the same block as prev
  -- try to use the same block as next
  -- use a new block if it is not reusing any blocks
  -- split blocks if both prev and next were using the same block, but this is not connecting with both
  -- update is_main_entry_block

  -- determine if it can connect with the block of the previous instruction
  local can_use_prev_block = inst.prev and can_use_same_block(inst.prev, inst)
  -- determine if it can connect with the block of the next instruction
  local can_use_next_block = inst.next and can_use_same_block(inst, inst.next)

  if not can_use_prev_block and not can_use_next_block then
    create_and_insert_block(func, inst)
    return
  end

  -- blocks from splitting
  local left_block, right_block

  if can_use_prev_block then
    inst.block = inst.prev.block
    if not can_use_next_block then
      -- with `can_use_next_block` being false, this is true: `inst.block.stop_inst == inst.prev`.
      inst.block.stop_inst = inst
      if inst.next and inst.next.block == inst.block then
        left_block, right_block = split_block(func, inst.block, inst, inst.next)
      end
    end
  else -- `can_use_next_block` is guaranteed to be true.
    inst.block = inst.next.block
    -- `can_use_prev_block` is guaranteed to be false,
    -- therefore this is also guaranteed to be true: `inst.block.start_inst == inst.next`.
    inst.block.start_inst = inst

    -- Again, `can_use_prev_block` is guaranteed to be false.
    if inst.prev and inst.prev.block == inst.block then
      left_block, right_block = split_block(func, inst.block, inst.prev, inst)
    end
  end

  if not left_block then
    return -- Did not split a block? Done.
  end

  -- The block has already been split, all that's left is handling the unfinished parts of that split,
  -- see the description of `split_block` for details.

  -- `right_block`'s start instruction could only be a label if that label is the newly inserted instruction,
  -- therefore nothing except `left_block` could link to it at the moment. Nothing special to do there.

  -- The target links for the `left_block` have not been created, however since there is no gap between
  -- `left_block` and `right_block` there is no special handling required before creating them, so:
  create_target_links_for_block(left_block)

  -- And done.
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

---@param func ILFunction
---@param inst ILJump|ILTest
local function update_blocks_for_new_jump_target_internal(func, inst)
  set_link_target_block(inst.block.jump_link, inst.label.block)
end

---@param func ILFunction
---@param inst ILJump|ILTest
local function update_blocks_for_new_jump_target(func, inst)
  assert_is_not_inst_group(inst)
  assert_has_blocks(func, "update_blocks_for_new_jump_target")
  update_blocks_for_new_jump_target_internal(func, inst)
end

---@param func ILFunction
---@param inst ILJump|ILTest
---@param target_label ILLabel
local function set_jump_target(func, inst, target_label)
  assert_is_not_inst_group(inst)
  assert_has_blocks(func, "set_jump_target")
  inst.label = target_label
  update_blocks_for_new_jump_target_internal(func, inst)
end

---@param link ILBlockLink
local function remove_link(link)
  if link.is_jump_link then
    link.source_block.jump_link = nil
  else
    link.source_block.straight_link = nil
  end
  util.remove_from_array_fast(link.target_block.source_links, link)
end

---@param func ILFunction
---@param left_block ILBlock
---@param right_block ILBlock
local function merge_blocks(func, left_block, right_block)
  -- These assertions are just restating what should have already been done to the 2 blocks.
  util.debug_assert(not left_block.jump_link)
  util.debug_assert(left_block.straight_link)
  remove_link(left_block.straight_link) -- Remove the link between left and right.
  util.debug_assert(not right_block.source_links[1]) -- After removal of the last link.

  -- Move the target links from the right block to the left block.
  left_block.straight_link = right_block.straight_link
  if left_block.straight_link then left_block.straight_link.source_block = left_block end
  left_block.jump_link = right_block.jump_link
  if left_block.jump_link then left_block.jump_link.source_block = left_block end

  -- Updating the `block` field for instructions.
  local inst = right_block.start_inst
  while true do
    inst.block = left_block
    if inst == right_block.stop_inst then break end
    inst = inst.next
  end

  ll.remove(func.blocks, right_block)
end

---@param left_block ILBlock
---@param right_block ILBlock
local function blocks_require_merge(left_block, right_block)
  return left_block.stop_inst.next == right_block.start_inst
    and can_use_same_block(left_block.stop_inst, right_block.start_inst)
end

---@param func ILFunction
---@param left_block ILBlock
---@param right_block ILBlock
local function try_merge_blocks(func, left_block, right_block)
  if blocks_require_merge(left_block, right_block) then
    merge_blocks(func, left_block, right_block)
  end
end

---Expects the given block's source_links to already be removed, except optionally one which is the previous
---block flowing into this block with a straight_link.\
---Excepts the jump_link of this block to already be removed, if it had one.\
---Merges the prev and next blocks if required.
---@param func ILFunction
---@param block ILBlock
local function remove_block(func, block)
  local inst = block.start_inst
  util.debug_assert(
    inst == block.stop_inst,
    "Removing a block that doesn't consist of a single instruction isn't supported."
  )

  ll.remove(func.blocks, block)
  if inst.prev and inst.prev.block.straight_link then
    util.debug_assert(inst.next, "Removing the last instruction where the second last instruction has a \z
      straight_link flowing into its block resulted in malformed IL."
    )
    set_link_target_block(inst.prev.block.straight_link, inst.next.block)

    try_merge_blocks(func, inst.prev.block, inst.next.block)
  end

  if block.straight_link then
    remove_link(block.straight_link)
  end

  if not inst.prev then
    inst.next.block.is_main_entry_block = true
  end

  util.debug_assert(not block.source_links[1], "There's still a source_link after removing a block.")
  util.debug_assert(not block.jump_link, "The jump_link is supposed to be removed before remove_block.")
end

---@param func ILFunction
---@param inst ILInstruction @ the already removed instruction
local function update_blocks_for_removed_inst(func, inst)
  assert_has_blocks(func, "update_blocks_for_removed_inst")
  -- remove a block if the inst is the only inst in that block
  -- change the start or stop inst of the block this inst was the start or stop inst
  -- or merge blocks if the new start/stop inst no longer separates the blocks
  -- update links when any of the above happens

  local block = inst.block
  local removed_start = block.start_inst == inst
  local removed_stop = block.stop_inst == inst

  if not removed_start and not removed_stop then
    return -- The instruction is in the middle of a block, nothing to do.
  end

  if inst.inst_type == "label" then
    local broken_link = linq(block.source_links):first(function(link) return link.is_jump_link end)
    if broken_link then
      util.abort("Removed a label instruction without removing all jumps or tests targeting it first. \z
        (index of removed inst: "..inst.index..", \z
        index of jump or test targeting it: "..broken_link.target_block.stop_inst.index..")"
      )
    end
  end

  -- remove jump link if this is a jump or test instruction
  if removed_stop and block.jump_link then
    remove_link(block.jump_link)
  end

  if removed_start and removed_stop then
    remove_block(func, block) -- remove the block for this instruction entirely
    return
  end

  if removed_start then -- only removed start
    block.start_inst = inst.next -- guaranteed to be part of the same block
  else -- only removed stop
    block.stop_inst = inst.prev -- guaranteed to be part of the same block
  end

  -- merge if necessary
  if inst.prev and inst.next then
    try_merge_blocks(func, inst.prev.block, inst.next.block)
  end
end

return {

  -- creating

  create_blocks = create_blocks,
  create_blocks_recursive = create_blocks_recursive,
  ensure_has_blocks = ensure_has_blocks,
  ensure_has_blocks_recursive = ensure_has_blocks_recursive,

  -- inserting

  update_blocks_for_new_inst = update_blocks_for_new_inst,

  -- modifying

  set_allow_modifying_inst_groups = set_allow_modifying_inst_groups,

  update_blocks_for_new_jump_target = update_blocks_for_new_jump_target,
  set_jump_target = set_jump_target,

  -- removing

  update_blocks_for_removed_inst = update_blocks_for_removed_inst,
}
