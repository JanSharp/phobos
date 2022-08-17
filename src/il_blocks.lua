
local util = require("util")
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

local eval_start_stop_for_regs
do
  local function visit_reg(data, inst, reg)
    if not reg.start_at then
      reg.start_at = inst
      data.all_regs[#data.all_regs+1] = reg
    end
    reg.stop_at = inst
  end

  local function visit_reg_list(data, inst, regs)
    for _, reg in ipairs(regs) do
      visit_reg(data, inst, reg)
    end
  end

  local function visit_ptr(data, inst, ptr)
    if ptr.ptr_type == "reg" then
      visit_reg(data, inst, ptr)
    end
  end

  local function visit_ptr_list(data, inst, ptrs)
    for _, ptr in ipairs(ptrs) do
      visit_ptr(data, inst, ptr)
    end
  end

  local reg_liveliness_lut = {
    ["move"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["get_upval"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
    end,
    ["set_upval"] = function(data, inst)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["get_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_reg(data, inst, inst.table_reg)
      visit_ptr(data, inst, inst.key_ptr)
    end,
    ["set_table"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg)
      visit_ptr(data, inst, inst.key_ptr)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["set_list"] = function(data, inst)
      visit_reg(data, inst, inst.table_reg)
      visit_ptr_list(data, inst, inst.right_ptrs)
    end,
    ["new_table"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
    end,
    ["concat"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_ptr_list(data, inst, inst.right_ptrs)
    end,
    ["binop"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      visit_ptr(data, inst, inst.left_ptr)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["unop"] = function(data, inst)
      visit_ptr(data, inst, inst.result_reg)
      visit_ptr(data, inst, inst.right_ptr)
    end,
    ["label"] = function(data, inst)
    end,
    ["jump"] = function(data, inst)
    end,
    ["test"] = function(data, inst)
      visit_ptr(data, inst, inst.condition_ptr)
    end,
    ["call"] = function(data, inst)
      visit_reg(data, inst, inst.func_reg)
      visit_ptr_list(data, inst, inst.arg_ptrs)
      visit_reg_list(data, inst, inst.result_regs)
    end,
    ["ret"] = function(data, inst)
      visit_ptr_list(data, inst, inst.ptrs)
    end,
    ["closure"] = function(data, inst)
      visit_reg(data, inst, inst.result_reg)
      for _, upval in ipairs(inst.func.upvals) do
        if upval.parent_type == "local" then
          visit_reg(data, inst, upval.reg_in_parent_func)
        end
      end
    end,
    ["vararg"] = function(data, inst)
      visit_reg_list(data, inst, inst.result_regs)
    end,
    ["scoping"] = function(data, inst)
      visit_reg_list(data, inst, inst.regs)
    end,
  }

  function eval_start_stop_for_regs(data)
    data.all_regs = {}
    local inst = data.func.instructions.first
    while inst do
      reg_liveliness_lut[inst.inst_type](data, inst)
      inst = inst.next
    end
  end
end

local eval_live_regs
do
  function eval_live_regs(data)
    local start_at_list_lut = {}
    local start_at_lut_lut = {}
    local stop_at_list_lut = {}
    local stop_at_lut_lut = {}
    for _, reg in ipairs(data.all_regs) do
      local list = start_at_list_lut[reg.start_at]
      local lut
      if not list then
        list = {}
        start_at_list_lut[reg.start_at] = list
        lut = {}
        start_at_lut_lut[reg.start_at] = lut
      else
        lut = start_at_lut_lut[reg.start_at]
      end
      list[#list+1] = reg
      lut[reg] = true
      -- copy paste
      list = stop_at_list_lut[reg.stop_at]
      if not list then
        list = {}
        stop_at_list_lut[reg.stop_at] = list
        lut = {}
        stop_at_lut_lut[reg.stop_at] = lut
      else
        lut = stop_at_lut_lut[reg.stop_at]
      end
      list[#list+1] = reg
      lut[reg] = true
    end

    local live_regs = {}
    local inst = data.func.instructions.first
    while inst do
      inst.live_regs = live_regs
      -- starting at this instruction, add them to live_regs for this instruction
      local list = start_at_list_lut[inst]
      if list then
        inst.regs_start_at_list = list
        inst.regs_start_at_lut = start_at_lut_lut[inst]
        for _, reg in ipairs(list) do
          live_regs[#live_regs+1] = reg
        end
      end
      live_regs = util.shallow_copy(live_regs)
      -- stopping at this instruction, remove them from live_regs for the next instruction
      local lut = stop_at_lut_lut[inst]
      if lut then
        inst.regs_stop_at_list = stop_at_list_lut[inst]
        inst.regs_stop_at_lut = lut
        local i = 1
        local j = 1
        local c = #live_regs
        while i <= c do
          local reg = live_regs[i]
          live_regs[i] = nil
          if not lut[reg] then -- if it's not stopping it's still alive
            live_regs[j] = reg
            j = j + 1
          end
          i = i + 1
        end
      end
      inst = inst.next
    end
  end
end

local eval_blocks
do
  -- label isn't in this list because labels can be the start of a block
  -- but if a label is not the first instruction in a block then it does still end the block
  -- so it's handled in the loop down below
  local block_ends = util.invert{"jump", "test", "ret"}
  local function create_block(data, inst)
    local block = {
      source_links = {},
      start_inst = inst,
      target_links = {},
    }
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

local link_blocks
do
  local function create_link(data, source_block, target_block)
    local link = {
      source_block = source_block,
      target_block = target_block,
      -- backwards jumps are 99% of the time a loop
      -- I'm not sure how to detect if it is a loop otherwise, but since this is 99% of the time correct
      -- it's good enough. Besides, a jump being marked as a loop even though it isn't doesn't cause harm
      -- while a jump that is a loop not being marked as a loop does cause harm
      is_loop = target_block.start_inst.index < source_block.start_inst.index,
    }
    source_block.target_links[#source_block.target_links+1] = link
    target_block.source_links[#target_block.source_links+1] = link
    return link
  end

  local function create_links_for_block(data, block)
    local last_inst = block.stop_inst
    local function assert_next()
      util.debug_assert(last_inst.next, "The next instruction of the last instruction of a block \z
        where the last instruction in the block is not a 'ret' or 'jump' instruction should be \z
        impossible to be nil."
      )
    end
    local inst_type = last_inst.inst_type
    if inst_type == "jump" then
      create_link(data, block, last_inst.label.block)
    elseif inst_type == "test" then
      assert_next()
      create_link(data, block, last_inst.next.block)
      create_link(data, block, last_inst.label.block)
    elseif inst_type == "ret" then
      -- doesn't link to anything
      block.is_return_block = true -- a flag for convenience
    else -- anything else just continues to the next block
      assert_next()
      create_link(data, block, last_inst.next.block)
    end
  end

  function link_blocks(data)
    local blocks = data.blocks
    blocks.first.is_main_entry_block = true
    local block = blocks.first
    while block do
      create_links_for_block(data, block)
      block = block.next
    end
  end
end

local function make_blocks(func)
  local data = {func = func}
  eval_start_stop_for_regs(data)
  eval_live_regs(data)
  eval_blocks(data)
  link_blocks(data)
  func.all_regs = data.all_regs
  func.blocks = data.blocks
  for _, inner_func in ipairs(func.inner_functions) do
    make_blocks(inner_func)
  end
end

return make_blocks
