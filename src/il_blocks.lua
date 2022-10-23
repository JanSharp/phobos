
local util = require("util")
local il = require("il_util")
local ill = require("indexed_linked_list")

-- A block is list of instructions which will be executed in order without any branches
-- blocks can have an arbitrary amount of source_links which are blocks potentially branching
-- into the block and may have 0 to 2 target_links which are blocks they are potentially branching
-- to themselves. It depends on the last instruction of the block:
-- "ret" - 0 target_links
-- "jump" - 1 target_links
-- "test" - 2 target_links
-- any other instruction - 1 target_links
--
-- labels are only valid as the very first instruction of a block
--
-- links are considered to be loop links if the target_block comes before the source_block
-- this is not 100% accurate but it is close enough

local eval_blocks
do
  -- label isn't in this list because labels can be the start of a block
  -- but if a label is not the first instruction in a block then it does still end the block
  -- so it's handled in the loop down below
  local block_ends = util.invert{"jump", "test", "ret"}
  local function create_block(data, inst)
    local block = il.new_block(inst, nil)
    inst.block = block
    local stop_inst = inst
    while not block_ends[inst.inst_type] do
      inst = inst.next
      if not inst or inst.inst_type == "label" then
        break
      end
      stop_inst = inst
      inst.block = block
    end
    block.stop_inst = stop_inst
    return block
  end

  function eval_blocks(data)
    local inst = data.func.instructions.first
    local blocks = ill.new(true)
    data.blocks = blocks
    while inst do
      local block = create_block(data, inst)
      ill.append(blocks, block)
      inst = block.stop_inst.next
    end
  end
end

local function link_blocks(data)
  local blocks = data.blocks
  blocks.first.is_main_entry_block = true
  local block = blocks.first
  while block do
    il.create_links_for_block(block)
    block = block.next
  end
end

local function make_blocks(func)
  local data = {func = func}
  eval_blocks(data)
  link_blocks(data)
  func.blocks = data.blocks
  func.has_blocks = true
  for _, inner_func in ipairs(func.inner_functions) do
    make_blocks(inner_func)
  end
end

return make_blocks
