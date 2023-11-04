
local ll = require("linked_list")
local il_borders = require("il_borders")
local il_real_liveliness = require("il_real_liveliness")

---@param func ILFunction
---@return ILLiveRegisterRange[] all_live_regs
local function build_graph(func)
  local all_live_regs = {} ---@type ILLiveRegisterRange[]
  local all_live_regs_lut = {} ---@type table<ILLiveRegisterRange, true>
  ---@param regs ILLiveRegisterRange[]
  local function add_real_live_regs(regs)
    for _, live_reg in ipairs(regs) do
      if not all_live_regs_lut[live_reg] then
        all_live_regs_lut[live_reg] = true
        all_live_regs[#all_live_regs+1] = live_reg
      end
      live_reg.adjacent_regs = live_reg.adjacent_regs or {}
      live_reg.adjacent_regs_lut = live_reg.adjacent_regs_lut or {}
      for _, other_live_reg in ipairs(regs) do
        if other_live_reg ~= live_reg and not live_reg.adjacent_regs_lut[other_live_reg] then
          live_reg.adjacent_regs_lut[other_live_reg] = true
          live_reg.adjacent_regs[#live_reg.adjacent_regs+1] = other_live_reg
        end
      end
    end
  end

  for border in il_borders.iterate_borders(func)--[[@as fun(): ILBorder]] do
    -- Ignore borders between blocks, because those don't have live regs, the links between blocks do instead.
    if border.prev_inst ~= border.prev_inst.block.stop_inst then
      add_real_live_regs(border.real_live_regs)
    end
  end

  for block in ll.iterate(func.blocks) do
    if block.straight_link then
      add_real_live_regs(block.straight_link.real_live_regs)
    end
    if block.jump_link then
      add_real_live_regs(block.jump_link.real_live_regs)
    end
  end

  return all_live_regs
end

---@param data ILRegColoringData
local function set_forced_colors(data)
  for i, reg in ipairs(data.func.param_regs) do
    local live_reg_range = data.func.param_execution_checkpoint.live_range_by_reg[reg]
    if live_reg_range then
      live_reg_range.forced_color = i
      live_reg_range.color = i
    end
  end
end

---Iterate key execution checkpoints this live reg range is alive at.\
---Those are:
---- Borders right after set_insts.
---- Links between blocks this reg range is alive at.
---- Borders right before get_insts.
---
---Does not return the save execution checkpoint twice.
---@param data ILRegColoringData
---@param live_reg ILLiveRegisterRange
---@return ILExecutionCheckpoint[]
local function get_crucial_checkpoints(data, live_reg)
  ---@type ILExecutionCheckpoint[]
  local checkpoints = {}
  ---@type table<ILExecutionCheckpoint, true>
  local checkpoints_lut = {}
  local function add(checkpoint)
    if checkpoints_lut[checkpoint] then return end
    checkpoints_lut[checkpoint] = true
    checkpoints[#checkpoints+1] = checkpoint
  end

  for _, get_inst in ipairs(live_reg.get_insts) do
    if get_inst.block.start_inst ~= get_inst then
      add(get_inst.prev_border)
    elseif get_inst.block.is_main_entry_block then
      add(data.func.param_execution_checkpoint)
    else
      for _, link in ipairs(get_inst.block.source_links) do
        add(link)
      end
    end
  end

  for _, set_inst in ipairs(live_reg.set_insts) do
    if set_inst.block.stop_inst ~= set_inst then
      add(set_inst.next_border)
    else
      if set_inst.block.straight_link then
        add(set_inst.block.straight_link)
      end
      if set_inst.block.jump_link then
        add(set_inst.block.jump_link)
      end
    end
  end

  -- TODO: It may also have to include all links where the live reg range is alive to actually ensure these
  -- lists of checkpoints are conclusive enough to determine which live ranges live longer than others

  return checkpoints
end

---@param data ILRegColoringData
local function sort_all_live_regs(data)
  for i, live_reg in pairs(data.all_live_regs) do
    ---@diagnostic disable-next-line: inject-field
    live_reg.deterministic_index = i
  end
  ---@type table<ILLiveRegisterRange, table<ILLiveRegisterRange, boolean>>
  local cache = {}
  ---@param live_reg ILLiveRegisterRange
  local function get_cache(live_reg)
    local reg_cache = cache[live_reg]
    if not reg_cache then
      reg_cache = {}
      cache[live_reg] = reg_cache
    end
    return reg_cache
  end
  table.sort(data.all_live_regs, function(left, right)
    local left_cache = get_cache(left)
    local result = left_cache[right]
    if result ~= nil then return result end
    for _, adjacent in ipairs(left.adjacent_regs) do
      local adjacent_cache = get_cache(adjacent)
      if adjacent_cache[left] ~= nil then goto continue end
      local adjacent_is_alive_for_entire_left = true
      local left_is_alive_for_entire_adjacent = true
      for _, checkpoint in ipairs(get_crucial_checkpoints(data, left)) do
        if checkpoint.live_range_by_reg[adjacent.reg] ~= adjacent then
          adjacent_is_alive_for_entire_left = false
          break
        end
      end
      for _, checkpoint in ipairs(get_crucial_checkpoints(data, adjacent)) do
        if checkpoint.live_range_by_reg[left.reg] ~= left then
          left_is_alive_for_entire_adjacent = false
          break
        end
      end
      local left_comes_before_adjacent
      if not adjacent_is_alive_for_entire_left and not left_is_alive_for_entire_adjacent then
        -- Tie breaker for when they both outlive each other at different points in the code.
        ---@diagnostic disable-next-line: undefined-field
        left_comes_before_adjacent = left.deterministic_index < adjacent.deterministic_index
      else
        left_comes_before_adjacent = adjacent_is_alive_for_entire_left
      end
      left_cache[adjacent] = left_comes_before_adjacent
      adjacent_cache[left] = not left_comes_before_adjacent
      ::continue::
    end
    return left_cache[right]
  end)
end

---@class ILRegColoringData
---@field func ILFunction
---@field all_live_regs ILLiveRegisterRange[]

---@param func ILFunction
local function color_live_regs(func)
  il_real_liveliness.ensure_has_real_reg_liveliness(func)
  ---@type ILRegColoringData
  local data = {
    func = func,
    all_live_regs = build_graph(func),
  }
  set_forced_colors(data)
  sort_all_live_regs(data)

  local used_colors = {}
  local total_colors = 0
  for i, live_reg in ipairs(data.all_live_regs) do
    if live_reg.forced_color then
      if live_reg.color > total_colors then
        total_colors = live_reg.color
      end
      goto continue
    end
    for _, adjacent_live_reg in ipairs(live_reg.adjacent_regs) do
      if adjacent_live_reg.color then
        used_colors[adjacent_live_reg.color] = i
      end
    end
    local free_color = 1
    while used_colors[free_color] == i do
      free_color = free_color + 1
    end
    if free_color > total_colors then
      total_colors = free_color
    end
    live_reg.color = free_color
    ::continue::
  end
end

---@param func ILFunction
local function color_live_regs_recursive(func)
  color_live_regs(func)
  for _, inner_func in ipairs(func.inner_functions) do
    color_live_regs_recursive(inner_func)
  end
end

--[[

- [x] convert all instruction groups into single special instructions before register coloration
- [x] lut from ILRegister to live range on each ILExecutionCheckpoint
- [ ] "must be at top" constraint on live reg ranges, implemented as a list of regs that must have a color
  before this live range gets a color, which then must all be lower than the color for this live reg range
- [ ] initial color feature, where a live range has a different color when it becomes alive, then the rest
  has their actual color. When compiling, a move will be inserted right after the initial set
- [ ] index for register groups, when compiling if a live range does not have a matching index, a move is
  inserted before the register list consuming instruction
- [x] somehow force the color of parameter registers
- [x] remember the instruction which set a live reg range
- [x] maybe remember all instructions which get a live reg range
- [ ] evaluate all live reg ranges which are not at top and not apart of register lists first
- [x] ignore internal regs
- [ ] live reg ranges which outlive a register group in both directions must be below the register list
  - [ ] unless it can be in the middle of the group without getting overwritten
- [ ] a register group is defined as a list of live reg ranges which must be below the list
  and an index which is the base index of the register group
  plus a bunch of live reg ranges which are actually apart of the register lists associated with an index
  offset from the group base index
  and a list of instructions associated with an index offset from the group base index
- [x] live regs must exist for block links
  - [x] live regs for borders which are actually never visited are nil.
- [x] list of live reg ranges which are alive from the beginning of the function, which must also match the
  list of parameters

]]

return {
  color_live_regs = color_live_regs,
  color_live_regs_recursive = color_live_regs_recursive,
}
