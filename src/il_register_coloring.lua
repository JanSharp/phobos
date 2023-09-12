
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

  local insts = func.instructions
  for border in il_borders.iterate_borders(func, insts.first.next_border, insts.last.prev_border)--[[@as fun(): ILBorder]] do
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

---@param func ILFunction
local function color_live_regs(func)
  il_real_liveliness.ensure_has_real_reg_liveliness(func)
  local all_live_regs = build_graph(func)
  local used_colors = {}
  local total_colors = 0
  for i, live_reg in ipairs(all_live_regs) do
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

- [x] lut from ILRegister to live range on each ILExecutionCheckpoint
- [ ] "must be at top" constraint on live reg ranges, implemented as a list of regs that must have a color
  before this live range gets a color, which then must all be lower than the color for this live reg range
- [ ] initial color feature, where a live range has a different color when it becomes alive, then the rest
  has their actual color. When compiling, a move will be inserted right after the initial set
- [ ] index for register groups, when compiling if a live range does not have a matching index, a move is
  inserted before the register list consuming instruction
- [ ] somehow force the color of parameter registers
- [ ] remember the instruction which set a live reg range
- [ ] maybe remember all instructions which get a live reg range
- [ ] evaluate all live reg ranges which are not at top and not apart of register lists first
- [ ] ignore internal regs
- [ ] live reg ranges which outlive a register group in both directions must be below the register list
  - [ ] unless it can be in the middle of the group without getting overwritten
- [ ] a register group is defined as a list of live reg ranges which must be below the list
  and an index which is the base index of the register group
  plus a bunch of live reg ranges which are actually apart of the register lists associated with an index
  offset from the group base index
  and a list of instructions associated with an index offset from the group base index
- [x] live regs must exist for block links
  - [ ] live regs for borders which are actually never visited are nil.
- [ ] list of live reg ranches which are alive from the beginning of the function, which must also match the
  list of parameters

]]

return {
  color_live_regs = color_live_regs,
  color_live_regs_recursive = color_live_regs_recursive,
}
