
local util = require("util")

----====----====----====----====----====----====----====----====----====----====----====----====----
-- utility
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param func ILFunction
---@param func_name string
local function assert_has_borders(func, func_name)
  util.debug_assert(func.has_borders, "Attempt to use 'il_borders."..func_name.."' with a func without borders.")
end

---@param func ILFunction
---@param start_border ILBorder? @ Inclusive. Default: `next_border` of the first instruction.
---@param stop_border ILBorder? @ Inclusive. Default: `prev_border` of the last instruction.
---@return fun(): ILBorder?
local function iterate_borders(func, start_border, stop_border)
  assert_has_borders(func, "iterate_borders")
  if start_border and stop_border and start_border.next_inst and stop_border.next_inst
    and start_border.next_inst.index > stop_border.next_inst.index
  then
    util.debug_abort("Attempt to iterate borders where the start_border comes after the stop_border.")
    -- Could also simply return an iterator that always returns 'nil'.
  end
  ---@type ILBorder?
  local next_border = start_border or func.instructions.first.next_border
  return function()
    local result = next_border
    if next_border == stop_border then
      next_border = nil
      stop_border = nil
    else
      -- If next_border is impossible to be nil because it would have entered the above if block already.
      -- This is ensured by the initial debug assert that the stop border comes after the start border.
      ---@cast next_border -nil
      next_border = next_border.next_inst.next_border
    end
    return result
  end
end

---NOTE: unfortunately these 2 functions contain a tiny bit of logic that would belong in other files

---@param func ILFunction
---@param border ILBorder
---@return ILBorder
local function copy_border(func, border)
  return {
    prev_inst = border.prev_inst,
    next_inst = border.next_inst,
    live_regs = util.optional_shallow_copy(border.live_regs),
  }
end

---@param func ILFunction
---@param left_inst ILInstruction
---@param right_inst ILInstruction
---@return ILBorder
local function create_empty_border(func, left_inst, right_inst)
  ---@type ILBorder
  local border = {
    prev_inst = left_inst,
    next_inst = right_inst,
    live_regs = (func.has_reg_liveliness and {} or nil)--[=[@as ILRegister[]]=],
  }
  left_inst.next_border = border
  right_inst.prev_border = border
  return border
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- creating
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param func ILFunction
local function create_borders(func)
  util.debug_assert(not func.has_borders, "The create_borders function is meant to be run for the initial \z
    creation of borders, however the given function already has borders."
  )
  func.has_borders = true

  local border = {prev_inst = func.instructions.first}
  local inst = func.instructions.first.next
  while inst do
    border.next_inst = inst
    inst.prev_border = border
    border.prev_inst.next_border = border
    border = {prev_inst = inst}
    inst = inst.next
  end
end

---@param func ILFunction
local function create_borders_recursive(func)
  create_borders(func)
  for _, inner_func in ipairs(func.inner_functions) do
    create_borders_recursive(inner_func)
  end
end

---@param func ILFunction
local function ensure_has_borders(func)
  if func.has_borders then return end
  create_borders(func)
end

---@param func ILFunction
local function ensure_has_borders_recursive(func)
  ensure_has_borders(func)
  for _, inner_func in ipairs(func.inner_functions) do
    ensure_has_borders_recursive(inner_func)
  end
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- inserting
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param func ILFunction
---@param inst ILInstruction
local function update_borders_for_new_inst(func, inst)
  assert_has_borders(func, "update_borders_for_new_inst")

  if not inst.prev or not inst.next then -- Was it was either prepended or appended?
    -- In either case the newly created border is completely empty.
    local left_inst = inst.prev or inst
    local right_inst = inst.next or inst
    create_empty_border(func, left_inst, right_inst)
    return
  end

  -- Otherwise it was inserted right where a border was.
  -- Duplicate that border and update the border's next_inst and prev_inst.
  local left_border = inst.prev.next_border
  local right_border = copy_border(func, left_border)
  left_border.next_inst = inst
  right_border.prev_inst = inst
  inst.prev_border = left_border
  inst.next_border = right_border
  inst.next.prev_border = right_border
end

----====----====----====----====----====----====----====----====----====----====----====----====----
-- removing
----====----====----====----====----====----====----====----====----====----====----====----====----

---@param func ILFunction
---@param inst ILInstruction
local function update_borders_for_removed_inst(func, inst)
  assert_has_borders(func, "update_borders_for_removed_inst")

  if not inst.prev then
    inst.next.prev_border = nil
    return
  end

  if not inst.next then
    inst.prev.next_border = nil
    return
  end

  -- keep the prev_border, discard of the next_border
  inst.next.prev_border = inst.prev_border
  inst.prev_border.next_inst = inst.next
end

return {

  -- utility

  iterate_borders = iterate_borders,

  -- creating

  create_borders = create_borders,
  create_borders_recursive = create_borders_recursive,
  ensure_has_borders = ensure_has_borders,
  ensure_has_borders_recursive = ensure_has_borders_recursive,

  -- inserting

  update_borders_for_new_inst = update_borders_for_new_inst,

  -- removing

  update_borders_for_removed_inst = update_borders_for_removed_inst,
}
