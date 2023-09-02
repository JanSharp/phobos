
local il_borders = require("il_borders")
local il_real_liveliness = require("il_real_liveliness")

---@param func ILFunction
---@return ILLiveRegisterRange[] all_live_regs
local function build_graph(func)
  local all_live_regs = {} ---@type ILLiveRegisterRange[]
  local all_live_regs_lut = {} ---@type table<ILLiveRegisterRange, true>
  local insts = func.instructions
  for border in il_borders.iterate_borders(func, insts.first.next_border, insts.last.prev_border)--[[@as fun(): ILBorder]] do
    for _, live_reg in ipairs(border.real_live_regs) do
      if not all_live_regs_lut[live_reg] then
        all_live_regs_lut[live_reg] = true
        all_live_regs[#all_live_regs+1] = live_reg
      end
      live_reg.adjacent_regs = live_reg.adjacent_regs or {}
      live_reg.adjacent_regs_lut = live_reg.adjacent_regs_lut or {}
      for _, other_live_reg in ipairs(border.real_live_regs) do
        if other_live_reg ~= live_reg and not live_reg.adjacent_regs_lut[other_live_reg] then
          live_reg.adjacent_regs_lut[other_live_reg] = true
          live_reg.adjacent_regs[#live_reg.adjacent_regs+1] = other_live_reg
        end
      end
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

return {
  color_live_regs = color_live_regs,
  color_live_regs_recursive = color_live_regs_recursive,
}
